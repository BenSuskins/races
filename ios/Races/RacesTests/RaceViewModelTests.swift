import XCTest
@testable import Races
import RacesKit

/// `@MainActor async` throughout — see the gotcha in CLAUDE.md.
final class RaceViewModelTests: XCTestCase {

    /// 2026-09-21 14:30 in London, as a fixed instant, so `race.date` below is
    /// genuinely "today" against the injected clock.
    private static let off = Date(timeIntervalSince1970: 1_789_997_400)
    private static let now = RaceViewModelTests.off.addingTimeInterval(-3_600)

    private func race(date: String = "2026-09-21") -> Race {
        Race(
            id: "rac_1", courseName: "Ascot", name: "A Race", offTime: "14:30",
            offDateTime: Self.off, date: date,
            runners: [
                .fixture(id: "hrs_1", name: "Frankel", clothNumber: 1),
                .fixture(id: "hrs_2", name: "Kyprios", clothNumber: 2),
                .fixture(id: "hrs_3", name: "Baaeed", clothNumber: 3),
            ])
    }

    private func marketProvider() -> FakeMarketDataProvider {
        FakeMarketDataProvider(
            markets: .success([
                .fixture(startTime: Self.off, runners: [
                    (clothNumber: 1, name: "Frankel"),
                    (clothNumber: 2, name: "Kyprios (IRE)"),
                    (clothNumber: 3, name: "Baaeed"),
                ])
            ]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.0, 2: 4.0, 3: 8.0])]))
    }

    @MainActor
    func test_aMatchedMarketAnchorsTheDisplayedAssessment() async throws {
        let model = RaceViewModel(
            race: race(),
            store: RacesStore(documents: InMemoryDocumentStore()),
            markets: MarketLoader(provider: marketProvider()),
            now: { Self.now })

        await model.loadIfNeeded()

        let assessment = try XCTUnwrap(model.assessment)
        XCTAssertFalse(assessment.isFormOnly)
        XCTAssertEqual(assessment.marketSource, .liveExchange)
        XCTAssertEqual(assessment.marketCoverage, 1)
    }

    @MainActor
    func test_openingARaceNeverRecordsATip() async {
        // `TipsViewModel` records the whole card. A ledger of the races the user
        // happened to tap on is a biased sample, and the favourite baseline
        // would then be measured against a different population from the tips.
        let store = RacesStore(documents: InMemoryDocumentStore())
        let model = RaceViewModel(
            race: race(),
            store: store,
            markets: MarketLoader(provider: marketProvider()),
            now: { Self.now })

        await model.loadIfNeeded()

        let tips = await store.tips
        XCTAssertEqual(tips.count, 0)
    }

    @MainActor
    func test_aRaceOutsideTheProvidersTwoDaysAsksForNoMarket() async throws {
        // The market endpoints take today or tomorrow, not a date. Guessing at
        // the nearer of the two would price this race off another day's card.
        let provider = marketProvider()
        let model = RaceViewModel(
            race: race(date: "2026-09-28"),
            store: RacesStore(documents: InMemoryDocumentStore()),
            markets: MarketLoader(provider: provider),
            now: { Self.now })

        await model.loadIfNeeded()

        XCTAssertEqual(provider.marketCalls, 0)
        XCTAssertTrue(try XCTUnwrap(model.assessment).isFormOnly)
    }

    @MainActor
    func test_withNoBetfairTheRaceIsStillAssessedOnForm() async throws {
        let model = RaceViewModel(
            race: race(),
            store: RacesStore(documents: InMemoryDocumentStore()),
            markets: MarketLoader(provider: nil),
            now: { Self.now })

        await model.loadIfNeeded()

        let assessment = try XCTUnwrap(model.assessment)
        XCTAssertTrue(assessment.isFormOnly)
        XCTAssertNotNil(assessment.selection)
    }

    @MainActor
    func test_aSecondLoadDoesNothing() async {
        // The screen is display-only, so re-entering it must not re-fetch or
        // re-rate: the number under the horse's name would change while the
        // recorded tip did not.
        let provider = marketProvider()
        let model = RaceViewModel(
            race: race(),
            store: RacesStore(documents: InMemoryDocumentStore()),
            markets: MarketLoader(provider: provider),
            now: { Self.now })

        await model.loadIfNeeded()
        await model.loadIfNeeded()

        XCTAssertEqual(provider.marketCalls, 1)
    }
}
