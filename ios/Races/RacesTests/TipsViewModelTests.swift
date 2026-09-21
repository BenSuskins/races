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
        unavailable: APIError? = nil
    ) -> (TipsViewModel, RacesStore) {
        let provider = FakeRacingDataProvider(racecards: .success(races))
        return (
            TipsViewModel(
                loader: RacecardLoader(provider: provider, store: store),
                store: store,
                unavailable: unavailable,
                now: { Self.now }),
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
        let bare = TipsViewModel(loader: nil, store: nil, unavailable: nil, now: { Self.now })

        await bare.load()

        guard case .failed(let error) = bare.state else {
            return XCTFail("Expected a failed state, got \(bare.state)")
        }
        XCTAssertTrue(error.isExpectedLimitation)
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
