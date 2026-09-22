import XCTest
@testable import Races
import RacesKit

/// `@MainActor async` throughout — see the gotcha in CLAUDE.md.
final class MarketLoaderTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let off = MarketLoaderTests.now.addingTimeInterval(3_600)

    private static let field = [
        (clothNumber: 1, name: "Frankel"),
        (clothNumber: 2, name: "Kyprios (IRE)"),
        (clothNumber: 3, name: "Baaeed"),
    ]

    private func race(id: String = "rac_1", courseName: String = "Ascot") -> Race {
        Race(
            id: id, courseName: courseName, name: "A Race", offTime: "2:30",
            offDateTime: Self.off, date: "2026-06-16",
            runners: [
                .fixture(id: "hrs_1", name: "Frankel", clothNumber: 1),
                .fixture(id: "hrs_2", name: "Kyprios", clothNumber: 2),
                .fixture(id: "hrs_3", name: "Baaeed", clothNumber: 3),
            ])
    }

    private func market(id: String = "1.234", venue: String = "Ascot") -> ExchangeMarket {
        .fixture(id: id, venue: venue, startTime: Self.off, runners: Self.field)
    }

    @MainActor
    func test_pricesArriveKeyedByOurHorseIDs() async {
        let provider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.5, 2: 4.0, 3: 9.0])]))
        let loader = MarketLoader(provider: provider)

        let load = await loader.load(races: [race()], day: .today, now: Self.now)

        let snapshot = load.snapshot(forRace: "rac_1")
        XCTAssertEqual(snapshot?.marketID, "1.234")
        XCTAssertEqual(snapshot?.price(for: "hrs_1")?.backPrice, 2.5)
        XCTAssertEqual(snapshot?.price(for: "hrs_3")?.backPrice, 9.0)
        XCTAssertEqual(load.pricedRaceCount, 1)
        XCTAssertNil(load.failure)
    }

    @MainActor
    func test_onlyMatchedMarketsArePriced() async {
        // Two markets at the same course and the same time — both candidates.
        // The other one loses on runner overlap, which is the only signal that
        // can actually separate them.
        let other = ExchangeMarket.fixture(
            id: "1.999", venue: "Ascot",
            startTime: Self.off,
            runners: [(clothNumber: 1, name: "Someone Else"),
                      (clothNumber: 2, name: "Another Horse"),
                      (clothNumber: 3, name: "A Third")])
        let provider = FakeMarketDataProvider(
            markets: .success([market(), other]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.5, 2: 4.0, 3: 9.0])]))
        let loader = MarketLoader(provider: provider)

        _ = await loader.load(races: [race()], day: .today, now: Self.now)

        // A book call per forty markets is the expensive part, so asking for a
        // market we cannot join is a request spent on nothing.
        XCTAssertEqual(provider.lastPricedMarketIDs, ["1.234"])
    }

    @MainActor
    func test_aRaceWithNoCandidateMarketCarriesItsRefusalAndNoSnapshot() async {
        let provider = FakeMarketDataProvider(
            markets: .success([market(venue: "Newmarket")]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.5])]))
        let loader = MarketLoader(provider: provider)

        let load = await loader.load(races: [race()], day: .today, now: Self.now)

        XCTAssertNil(load.snapshot(forRace: "rac_1"))
        XCTAssertEqual(load.refusals["rac_1"], .noCandidate)
        // Not a failure: the exchange answered, the race simply did not match,
        // and the rater is built to fall back to form for exactly this.
        XCTAssertNil(load.failure)
    }

    @MainActor
    func test_aBookWithNoUsablePricesIsNotTreatedAsAMarket() async {
        // The join succeeds and every price is empty. The rater would fall back
        // to form on its own, but the coverage line would still claim this race
        // was priced — and that line exists to show when it is not.
        let empty = ExchangeMarketPrices(
            marketID: "1.234", status: "OPEN", capturedAt: Self.now, isDelayed: true,
            prices: [1_001: RunnerPrice(), 1_002: RunnerPrice(), 1_003: RunnerPrice()])
        let provider = FakeMarketDataProvider(
            markets: .success([market()]), prices: .success([empty]))
        let loader = MarketLoader(provider: provider)

        let load = await loader.load(races: [race()], day: .today, now: Self.now)

        XCTAssertNil(load.snapshot(forRace: "rac_1"))
        XCTAssertEqual(load.pricedRaceCount, 0)
    }

    @MainActor
    func test_noProviderIsReportedAsNotConfiguredRatherThanAFailure() async {
        let loader = MarketLoader(provider: nil)

        let load = await loader.load(races: [race()], day: .today, now: Self.now)

        XCTAssertFalse(loader.isConfigured)
        XCTAssertEqual(load.failure, .notConfigured(provider: "Betfair"))
        XCTAssertTrue(load.snapshots.isEmpty)
    }

    @MainActor
    func test_aRefusedLoginIsCarriedWithBetfairsOwnReason() async {
        let provider = FakeMarketDataProvider(
            markets: .failure(BetfairLoginFailure(code: "SECURITY_QUESTION_REQUIRED")))
        let loader = MarketLoader(provider: provider)

        let load = await loader.load(races: [race()], day: .today, now: Self.now)

        XCTAssertTrue(load.snapshots.isEmpty)
        // Not `.network(.unknown)`, which is what `APIError.from` would make of
        // it — "couldn't reach the exchange" sends the user looking for a
        // network problem they do not have.
        guard let failure = load.failure, case .badRequest(let message) = failure else {
            return XCTFail(
                "Expected a bad request carrying the reason, got \(String(describing: load.failure))")
        }
        XCTAssertEqual(message?.contains("SECURITY_QUESTION_REQUIRED"), true)
    }

    @MainActor
    func test_badCredentialsAreReportedAsUnauthorized() async {
        // The one refusal where re-entering credentials is the answer.
        let provider = FakeMarketDataProvider(
            markets: .failure(BetfairLoginFailure(code: "INVALID_USERNAME_OR_PASSWORD")))
        let loader = MarketLoader(provider: provider)

        let load = await loader.load(races: [race()], day: .today, now: Self.now)

        XCTAssertEqual(load.failure, .unauthorized)
    }

    @MainActor
    func test_aFailedCatalogueIsNotRetriedOnEveryLoad() async {
        // A latched 2FA refusal retried on every pull to refresh looks like a
        // hang and could lock the account.
        let provider = FakeMarketDataProvider(
            markets: .failure(BetfairLoginFailure(code: "SECURITY_QUESTION_REQUIRED")))
        let loader = MarketLoader(provider: provider)

        _ = await loader.load(races: [race()], day: .today, now: Self.now)
        _ = await loader.load(races: [race()], day: .today, now: Self.now.addingTimeInterval(60))

        XCTAssertEqual(provider.marketCalls, 1)

        // But held for the shorter window, so a transient failure does not
        // strand the screen on form-only for a quarter of an hour.
        _ = await loader.load(races: [race()], day: .today, now: Self.now.addingTimeInterval(6 * 60))
        XCTAssertEqual(provider.marketCalls, 2)
    }

    // MARK: - Caching

    @MainActor
    func test_aSecondLoadInsideTheWindowCostsNoRequests() async {
        let provider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.5, 2: 4.0, 3: 9.0])]))
        let loader = MarketLoader(provider: provider)

        _ = await loader.load(races: [race()], day: .today, now: Self.now)
        _ = await loader.load(races: [race()], day: .today, now: Self.now.addingTimeInterval(60))

        XCTAssertEqual(provider.marketCalls, 1)
        XCTAssertEqual(provider.priceCalls, 1)
    }

    @MainActor
    func test_pricesGoStaleBeforeTheCatalogueDoes() async {
        let provider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.5, 2: 4.0, 3: 9.0])]))
        let loader = MarketLoader(provider: provider)

        _ = await loader.load(races: [race()], day: .today, now: Self.now)
        // Past the five-minute price window, inside the fifteen-minute catalogue
        // one: prices move through an afternoon, the field does not.
        _ = await loader.load(races: [race()], day: .today, now: Self.now.addingTimeInterval(6 * 60))

        XCTAssertEqual(provider.marketCalls, 1)
        XCTAssertEqual(provider.priceCalls, 2)
    }

    @MainActor
    func test_forcingARefreshRefetchesBoth() async {
        let provider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.5, 2: 4.0, 3: 9.0])]))
        let loader = MarketLoader(provider: provider)

        _ = await loader.load(races: [race()], day: .today, now: Self.now)
        _ = await loader.load(races: [race()], day: .today, forceRefresh: true, now: Self.now)

        XCTAssertEqual(provider.marketCalls, 2)
        XCTAssertEqual(provider.priceCalls, 2)
    }

    @MainActor
    func test_changingTheProviderDiscardsWhatTheOldOneFetched() async {
        let first = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.5, 2: 4.0, 3: 9.0])]))
        let loader = MarketLoader(provider: first)
        _ = await loader.load(races: [race()], day: .today, now: Self.now)

        let second = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 3.0, 2: 4.0, 3: 9.0])]))
        loader.use(provider: second)
        let load = await loader.load(races: [race()], day: .today, now: Self.now)

        // Prices fetched under another app key are not ours to show.
        XCTAssertEqual(second.marketCalls, 1)
        XCTAssertEqual(load.snapshot(forRace: "rac_1")?.price(for: "hrs_1")?.backPrice, 3.0)
    }

    @MainActor
    func test_tomorrowIsLabelledForecastRatherThanLive() async {
        let provider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.5, 2: 4.0, 3: 9.0])]))
        let loader = MarketLoader(provider: provider)

        let load = await loader.load(races: [race()], day: .tomorrow, now: Self.now)

        // There is no money in tomorrow's book, so calling it a live exchange
        // price would overstate the anchor the model is leaning on.
        XCTAssertEqual(load.snapshot(forRace: "rac_1")?.source, .forecast)
    }

    @MainActor
    func test_theTwoDaysAreCachedSeparately() async {
        let provider = FakeMarketDataProvider(
            markets: .success([market()]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.5, 2: 4.0, 3: 9.0])]))
        let loader = MarketLoader(provider: provider)

        _ = await loader.load(races: [race()], day: .today, now: Self.now)
        _ = await loader.load(races: [race()], day: .tomorrow, now: Self.now)

        XCTAssertEqual(provider.marketCalls, 2)
    }
}
