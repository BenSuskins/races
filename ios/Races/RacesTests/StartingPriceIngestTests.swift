import XCTest
@testable import Races
import RacesKit

/// The app-side half of getting a Betfair SP onto a settled tip.
///
/// `AppEnvironment.refreshResults()` is the single path for collecting results,
/// shared by launch, the Record tab and the background task. It now makes a
/// second call — Betfair's settled starting prices — and the thing worth
/// asserting is that the second call can fail, be absent, or return nothing
/// without costing the first one.
final class StartingPriceIngestTests: XCTestCase {

    private static let off = Date(timeIntervalSince1970: 1_800_000_000)
    private static let afterwards = StartingPriceIngestTests.off.addingTimeInterval(1_800)

    private static let credentials: [CredentialSlot: String] = [
        .racingAPIUsername: "ben",
        .racingAPIPassword: "secret",
        .betfairAppKey: "appkey",
        .betfairUsername: "ben",
        .betfairPassword: "secret",
    ]

    private func race() -> Race {
        Race(
            id: "rac_1", courseName: "Ascot", name: "A Race", offTime: "2:30",
            offDateTime: Self.off, date: "2026-06-16",
            runners: [
                .fixture(id: "hrs_1", name: "Frankel", clothNumber: 1),
                .fixture(id: "hrs_2", name: "Kyprios", clothNumber: 2),
                .fixture(id: "hrs_3", name: "Baaeed", clothNumber: 3),
            ])
    }

    private func market() -> ExchangeMarket {
        .fixture(startTime: Self.off, runners: [
            (clothNumber: 1, name: "Frankel"),
            (clothNumber: 2, name: "Kyprios (IRE)"),
            (clothNumber: 3, name: "Baaeed"),
        ])
    }

    /// Records the whole card with market references, exactly as Tips does, so
    /// the tips under test carry the coordinates a real one would.
    @MainActor
    private func storeWithRecordedTip(
        marketProvider: FakeMarketDataProvider
    ) async -> RacesStore {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()
        let loader = MarketLoader(provider: marketProvider)
        let load = await loader.load(
            races: [race()], day: .today, now: Self.off.addingTimeInterval(-3_600))
        await store.assessAndRecord(
            [race()],
            markets: load.snapshots,
            references: load.references,
            now: Self.off.addingTimeInterval(-3_600))
        return store
    }

    @MainActor
    private func makeEnvironment(
        store: RacesStore,
        racing: FakeRacingDataProvider,
        market: FakeMarketDataProvider
    ) -> AppEnvironment {
        AppEnvironment(
            credentials: InMemoryCredentialsStore(Self.credentials),
            store: store,
            makeRacingProvider: { _ in racing },
            makeMarketProvider: { _ in market })
    }

    @MainActor
    func test_aSettledTipEndsUpWithItsBetfairPrice() async throws {
        let marketProvider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.0, 2: 4.0, 3: 8.0])]),
            // 1.234 is `ExchangeMarket.fixture`'s default id; 1_001 is the
            // selection id it derives for cloth number 1.
            startingPrices: .success(["1.234": [1_001: 4.6]]))
        let store = await storeWithRecordedTip(marketProvider: marketProvider)
        let racing = FakeRacingDataProvider(
            results: .success([.settleable(winner: "hrs_1")]))
        let environment = makeEnvironment(
            store: store, racing: racing, market: marketProvider)

        let ingestion = await environment.refreshResults(now: Self.afterwards)

        XCTAssertEqual(ingestion?.tipsSettled, 1)
        let tip = try XCTUnwrap(await store.tip(forRace: "rac_1"))
        XCTAssertEqual(tip.outcome?.isWin, true)
        // The number that makes ROI possible at all: the free results endpoint
        // carries no starting price.
        XCTAssertEqual(tip.outcome?.betfairSP, 4.6)
    }

    @MainActor
    func test_onlyTheMarketsThatNeedAPriceAreAskedFor() async throws {
        let marketProvider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.0, 2: 4.0, 3: 8.0])]),
            startingPrices: .success(["1.234": [1_001: 4.6]]))
        let store = await storeWithRecordedTip(marketProvider: marketProvider)
        let racing = FakeRacingDataProvider(
            results: .success([.settleable(winner: "hrs_1")]))
        let environment = makeEnvironment(
            store: store, racing: racing, market: marketProvider)

        await environment.refreshResults(now: Self.afterwards)
        XCTAssertEqual(marketProvider.lastStartingPriceMarketIDs, ["1.234"])

        // Second pass: the tip is settled with a price, so there is nothing left
        // to ask about and the exchange is not troubled again.
        await environment.refreshResults(now: Self.afterwards.addingTimeInterval(600))
        XCTAssertEqual(marketProvider.startingPriceCalls, 1)
    }

    @MainActor
    func test_aFailedStartingPriceCallStillSettlesTheTip() async throws {
        // The two calls are independent on purpose. Losing the ROI figure for a
        // race is a cost; losing the strike rate as well would be a bug, and the
        // free results endpoint is today-only so there is no second chance.
        let marketProvider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.0, 2: 4.0, 3: 8.0])]),
            startingPrices: .failure(APIError.offline))
        let store = await storeWithRecordedTip(marketProvider: marketProvider)
        let racing = FakeRacingDataProvider(
            results: .success([.settleable(winner: "hrs_1")]))
        let environment = makeEnvironment(
            store: store, racing: racing, market: marketProvider)

        let ingestion = await environment.refreshResults(now: Self.afterwards)

        XCTAssertEqual(ingestion?.tipsSettled, 1)
        let tip = try XCTUnwrap(await store.tip(forRace: "rac_1"))
        XCTAssertEqual(tip.outcome?.isWin, true)
        XCTAssertNil(tip.outcome?.betfairSP)
    }

    @MainActor
    func test_anUnsettledMarketYieldsNoPriceRatherThanZero() async throws {
        // Betfair omits `actualSP` until a market settles, so the reply can be
        // empty for a race that has run. A zero would read as a starting price
        // of evens-ish and wreck the ROI figure it was meant to inform.
        let marketProvider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.0, 2: 4.0, 3: 8.0])]),
            startingPrices: .success([:]))
        let store = await storeWithRecordedTip(marketProvider: marketProvider)
        let racing = FakeRacingDataProvider(
            results: .success([.settleable(winner: "hrs_1")]))
        let environment = makeEnvironment(
            store: store, racing: racing, market: marketProvider)

        await environment.refreshResults(now: Self.afterwards)

        let tip = try XCTUnwrap(await store.tip(forRace: "rac_1"))
        XCTAssertEqual(tip.outcome?.isWin, true)
        XCTAssertNil(tip.outcome?.betfairSP)
    }

    @MainActor
    func test_withNoBetfairTheResultsPassIsUnchanged() async throws {
        // The app has to keep working with the Racing API alone. Strike rate
        // survives; ROI is what is lost, and the report counts those tips
        // separately rather than hiding them.
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()
        await store.assessAndRecord(
            [race()], now: Self.off.addingTimeInterval(-3_600))
        let racing = FakeRacingDataProvider(
            results: .success([.settleable(winner: "hrs_1")]))
        let environment = AppEnvironment(
            credentials: InMemoryCredentialsStore([
                .racingAPIUsername: "ben", .racingAPIPassword: "secret",
            ]),
            store: store,
            makeRacingProvider: { _ in racing },
            makeMarketProvider: { _ in FakeMarketDataProvider() })

        let ingestion = await environment.refreshResults(now: Self.afterwards)

        XCTAssertNil(environment.marketProvider)
        XCTAssertEqual(ingestion?.tipsSettled, 1)
        let tip = try XCTUnwrap(await store.tip(forRace: "rac_1"))
        XCTAssertEqual(tip.outcome?.isWin, true)
        XCTAssertNil(tip.marketReference)
    }

    @MainActor
    func test_anUnmatchedRaceIsNeverAskedAbout() async throws {
        // No reference, so no market id — asking would be a request spent on a
        // race the exchange cannot answer for.
        let marketProvider = FakeMarketDataProvider(
            markets: .success([market()]),
            startingPrices: .success(["1.234": [1_001: 4.6]]))
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()
        await store.assessAndRecord(
            [race()], now: Self.off.addingTimeInterval(-3_600))
        let racing = FakeRacingDataProvider(
            results: .success([.settleable(winner: "hrs_1")]))
        let environment = makeEnvironment(
            store: store, racing: racing, market: marketProvider)

        await environment.refreshResults(now: Self.afterwards)

        XCTAssertEqual(marketProvider.startingPriceCalls, 0)
    }

    @MainActor
    func test_theReferenceIsRecordedEvenWhenNothingWasPricedLive() async throws {
        // A matched market with an empty book. `MarketLoader` drops the snapshot
        // so the tip is form-only — but the reference is kept, because the race
        // still settles with a Betfair SP hours later and that is the ROI.
        let emptyBook = ExchangeMarketPrices(
            marketID: "1.234", status: "OPEN", capturedAt: Self.off, isDelayed: true,
            prices: [1_001: RunnerPrice(), 1_002: RunnerPrice(), 1_003: RunnerPrice()])
        let marketProvider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([emptyBook]),
            startingPrices: .success(["1.234": [1_001: 5.2]]))
        let store = await storeWithRecordedTip(marketProvider: marketProvider)

        let recorded = try XCTUnwrap(await store.tip(forRace: "rac_1"))
        XCTAssertTrue(recorded.wasFormOnly)
        XCTAssertEqual(recorded.marketReference?.marketID, "1.234")

        let racing = FakeRacingDataProvider(
            results: .success([.settleable(winner: "hrs_1")]))
        let environment = makeEnvironment(
            store: store, racing: racing, market: marketProvider)
        await environment.refreshResults(now: Self.afterwards)

        let settled = try XCTUnwrap(await store.tip(forRace: "rac_1"))
        XCTAssertEqual(settled.outcome?.betfairSP, 5.2)
    }
}
