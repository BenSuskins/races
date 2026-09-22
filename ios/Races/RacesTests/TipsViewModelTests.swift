import XCTest
@testable import Races
import RacesKit

/// `@MainActor async` throughout — see the gotcha in CLAUDE.md.
final class TipsViewModelTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private func upcoming(id: String = "rac_1", minutesAway: Int = 60) -> Race {
        Race(
            id: id, courseName: "Ascot", name: "A Race", offTime: "2:30",
            offDateTime: Self.now.addingTimeInterval(TimeInterval(minutesAway * 60)),
            date: "2026-06-16",
            runners: [
                .fixture(id: "\(id)-a", officialRating: 100),
                .fixture(id: "\(id)-b", officialRating: 70),
                .fixture(id: "\(id)-c", officialRating: 40),
            ])
    }

    @MainActor
    private func makeModel(
        races: [Race],
        store: RacesStore = RacesStore(documents: InMemoryDocumentStore()),
        markets: MarketLoader? = nil,
        unavailable: APIError? = nil,
        now: Date = TipsViewModelTests.now
    ) -> (TipsViewModel, RacesStore) {
        let provider = FakeRacingDataProvider(racecards: .success(races))
        return (
            TipsViewModel(
                loader: RacecardLoader(provider: provider, store: store),
                markets: markets,
                store: store,
                unavailable: unavailable,
                now: { now }),
            store
        )
    }

    @MainActor
    func test_producesOneSelectionPerUpcomingRace() async throws {
        let (model, _) = makeModel(races: [upcoming(id: "rac_1"), upcoming(id: "rac_2")])

        await model.load()

        let selections = try XCTUnwrap(model.state.value)
        XCTAssertEqual(selections.count, 2)
        XCTAssertNotNil(selections.first?.selection)
    }

    @MainActor
    func test_selectionsAreOrderedByOffTime() async throws {
        let (model, _) = makeModel(races: [
            upcoming(id: "late", minutesAway: 120),
            upcoming(id: "early", minutesAway: 30),
        ])

        await model.load()

        let selections = try XCTUnwrap(model.state.value)
        XCTAssertEqual(selections.map(\.race.id), ["early", "late"])
    }

    @MainActor
    func test_racesThatHaveRunAreDroppedNotRated() async throws {
        let alreadyRun = Race(
            id: "gone", courseName: "Ascot", name: "A Race", offTime: "1:00",
            offDateTime: Self.now.addingTimeInterval(-3_600), date: "2026-06-16",
            runners: [.fixture(id: "x"), .fixture(id: "y")])
        let (model, store) = makeModel(races: [alreadyRun, upcoming(id: "live")])

        await model.load()

        // Showing a selection for a finished race invites reading it as a tip
        // that was never actually given.
        let selections = try XCTUnwrap(model.state.value)
        XCTAssertEqual(selections.map(\.race.id), ["live"])
        let tips = await store.tips
        XCTAssertEqual(tips.map(\.raceID), ["live"])
    }

    @MainActor
    func test_loadingRecordsATipForEveryRaceOnTheCard() async {
        let (model, store) = makeModel(races: [upcoming(id: "rac_1"), upcoming(id: "rac_2")])

        await model.load()

        // Recording the whole card, not just races the user opened, is what keeps
        // the accuracy record an unbiased sample.
        let tips = await store.tips
        XCTAssertEqual(Set(tips.map(\.raceID)), ["rac_1", "rac_2"])
    }

    @MainActor
    func test_refreshingRevisesADraftRatherThanDuplicatingIt() async {
        let (model, store) = makeModel(races: [upcoming(id: "rac_1")])

        await model.load()
        await model.load(forceRefresh: true)

        let tips = await store.tips
        XCTAssertEqual(tips.count, 1, "A tip is keyed by race, and a draft is revised in place")
    }

    @MainActor
    func test_aTipInsideTheSealWindowIsReportedAsSealed() async throws {
        // Four minutes out: inside the five-minute seal window.
        let (model, _) = makeModel(races: [upcoming(id: "rac_1", minutesAway: 4)])

        await model.load()

        let selections = try XCTUnwrap(model.state.value)
        XCTAssertEqual(selections.first?.isSealed, true)
    }

    @MainActor
    func test_aTipWellBeforeTheOffIsNotSealed() async throws {
        let (model, _) = makeModel(races: [upcoming(id: "rac_1", minutesAway: 60)])

        await model.load()

        let selections = try XCTUnwrap(model.state.value)
        XCTAssertEqual(selections.first?.isSealed, false)
    }

    @MainActor
    func test_withoutBetfairEverySelectionIsFlaggedFormOnly() async throws {
        let (model, _) = makeModel(races: [upcoming(id: "rac_1")])

        await model.load()

        // The UI keys off this to say so rather than implying a market-anchored
        // number the app cannot produce yet.
        let selections = try XCTUnwrap(model.state.value)
        XCTAssertTrue(try XCTUnwrap(selections.first).assessment.isFormOnly)
    }

    @MainActor
    func test_anEmptyCardIsNotAnError() async throws {
        let (model, _) = makeModel(races: [])

        await model.load()

        let selections = try XCTUnwrap(model.state.value)
        XCTAssertEqual(selections.count, 0)
    }

    @MainActor
    func test_noCredentialsReportsAnExpectedLimitation() async {
        let bare = TipsViewModel(
            loader: nil, markets: nil, store: nil, unavailable: nil, now: { Self.now })

        await bare.load()

        guard case .failed(let error) = bare.state else {
            return XCTFail("Expected a failed state, got \(bare.state)")
        }
        XCTAssertTrue(error.isExpectedLimitation)
    }

    // MARK: - Markets

    @MainActor
    func test_aMatchedMarketAnchorsTheTipAndIsReportedAsCovered() async throws {
        let race = Race(
            id: "rac_1", courseName: "Ascot", name: "A Race", offTime: "2:30",
            offDateTime: Self.now.addingTimeInterval(3_600), date: "2026-06-16",
            runners: [
                .fixture(id: "hrs_1", name: "Frankel", clothNumber: 1),
                .fixture(id: "hrs_2", name: "Kyprios", clothNumber: 2),
                .fixture(id: "hrs_3", name: "Baaeed", clothNumber: 3),
            ])
        let provider = FakeMarketDataProvider(
            markets: .success([
                .fixture(startTime: race.offDateTime!, runners: [
                    (clothNumber: 1, name: "Frankel"),
                    (clothNumber: 2, name: "Kyprios (IRE)"),
                    (clothNumber: 3, name: "Baaeed"),
                ])
            ]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.0, 2: 4.0, 3: 8.0])]))
        let (model, _) = makeModel(
            races: [race], markets: MarketLoader(provider: provider))

        await model.load()

        let selections = try XCTUnwrap(model.state.value)
        XCTAssertFalse(selections[0].assessment.isFormOnly)
        XCTAssertEqual(selections[0].assessment.marketSource, .liveExchange)
        XCTAssertEqual(model.marketCoverage?.pricedRaces, 1)
        XCTAssertEqual(model.marketCoverage?.totalRaces, 1)
        XCTAssertTrue(model.marketCoverage?.isComplete == true)
    }

    @MainActor
    func test_noBetfairLeavesTipsFormOnlyRatherThanFailing() async throws {
        // The whole screen has to keep working without a market. This is the
        // case the app ships in until Betfair is configured, and treating it as
        // an error would leave a working card behind an error banner.
        let (model, _) = makeModel(
            races: [upcoming()], markets: MarketLoader(provider: nil))

        await model.load()

        let selections = try XCTUnwrap(model.state.value)
        XCTAssertEqual(selections.count, 1)
        XCTAssertTrue(selections[0].assessment.isFormOnly)
        XCTAssertEqual(model.marketCoverage?.pricedRaces, 0)
        XCTAssertEqual(model.marketCoverage?.failure, .notConfigured(provider: "Betfair"))
    }

    @MainActor
    func test_aPartlyPricedCardIsReportedAsPartlyPriced() async throws {
        // Two races, one market. Coverage has to show the shortfall: eighteen
        // form-only tips in twenty is a materially weaker card than twenty
        // market-anchored ones, and this is the only place that is visible.
        let matched = Race(
            id: "matched", courseName: "Ascot", name: "A Race", offTime: "2:30",
            offDateTime: Self.now.addingTimeInterval(3_600), date: "2026-06-16",
            runners: [
                .fixture(id: "hrs_1", name: "Frankel", clothNumber: 1),
                .fixture(id: "hrs_2", name: "Kyprios", clothNumber: 2),
                .fixture(id: "hrs_3", name: "Baaeed", clothNumber: 3),
            ])
        let unmatched = upcoming(id: "unmatched", minutesAway: 120)
        let provider = FakeMarketDataProvider(
            markets: .success([
                .fixture(startTime: matched.offDateTime!, runners: [
                    (clothNumber: 1, name: "Frankel"),
                    (clothNumber: 2, name: "Kyprios (IRE)"),
                    (clothNumber: 3, name: "Baaeed"),
                ])
            ]),
            prices: .success([.fixture(backPricesByClothNumber: [1: 2.0, 2: 4.0, 3: 8.0])]))
        let (model, _) = makeModel(
            races: [matched, unmatched], markets: MarketLoader(provider: provider))

        await model.load()

        let selections = try XCTUnwrap(model.state.value)
        XCTAssertEqual(selections.count, 2)
        XCTAssertEqual(model.marketCoverage?.pricedRaces, 1)
        XCTAssertEqual(model.marketCoverage?.totalRaces, 2)
        XCTAssertFalse(model.marketCoverage?.isComplete == true)
        XCTAssertNil(model.marketCoverage?.failure)
    }

    @MainActor
    func test_theInjectedClockDecidesWhatHasRunNotTheRealOne() async throws {
        // The direction that actually proves it. This race is decades in the
        // future, so `Race.hasStarted` — which reads the real `Date()` — would
        // say it has not run. Our clock is a minute later than the off, so it
        // has, and it must be dropped.
        //
        // The reverse direction is what broke: every fixture off time is in 1970,
        // so against the real clock the whole card read as already run and Tips
        // produced nothing at all.
        let off = Date(timeIntervalSince1970: 4_000_000_000)
        let race = Race(
            id: "rac_1", courseName: "Ascot", name: "A Race", offTime: "2:30",
            offDateTime: off, date: "2096-10-08",
            runners: [.fixture(id: "a", officialRating: 100),
                      .fixture(id: "b", officialRating: 60)])
        let (model, store) = makeModel(races: [race], now: off.addingTimeInterval(60))

        await model.load()

        let selections = try XCTUnwrap(model.state.value)
        XCTAssertEqual(selections.count, 0, "Past by our clock, so not tipped")
        let tips = await store.tips
        XCTAssertEqual(tips.count, 0, "And never recorded — the sealing rule")
    }

    @MainActor
    func test_theArchiveCountIsSurfacedForTheDisclaimer() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.ingest(results: [
            .fixture(id: "past_1", finishers: [.fixture(horseID: "a", position: 1)]),
        ])
        let (model, _) = makeModel(races: [upcoming(id: "rac_1")], store: store)

        await model.load()

        XCTAssertEqual(model.archivedRaceCount, 1)
    }
}
