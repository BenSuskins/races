import XCTest
@testable import Races
import RacesKit

/// Every test is `@MainActor async`; see the gotcha in CLAUDE.md.
final class RecordViewModelTests: XCTestCase {

    private func tip(_ id: String, outcome: TipOutcome?) -> TipRecord {
        TipRecord(
            raceID: id, raceDate: "2026-06-16", offAt: nil, courseName: "Ascot", raceName: "A Race",
            raceType: .flat, fieldSizeAtTip: 8, selectionHorseID: "h", selectionHorseName: "H",
            predictedProbability: 0.3, marketProbabilityAtTip: nil, marketBackPriceAtTip: nil,
            marketFavouriteHorseID: nil, agreedWithFavourite: nil, wasFormOnly: true, confidence: .medium,
            modelVersion: RaceRater.modelVersion, weightsID: "v2", contributions: [],
            createdAt: Date(timeIntervalSince1970: 0), outcome: outcome)
    }

    @MainActor
    func test_theReportIsTheServers() async throws {
        let record = ServerRecord.fixture(
            tips: [tip("a", outcome: .won(betfairSP: 4)), tip("b", outcome: .lost(position: 3, betfairSP: 6))],
            sources: ["server": 1, "device:phone": 1],
            archivedRaces: 12)
        let model = RecordViewModel(link: ServerLink(server: FakeRacesServer(record: .success(record))), store: nil)

        await model.load()

        let report = try XCTUnwrap(model.state.value)
        XCTAssertEqual(report.settled, 2)
        XCTAssertEqual(report.wins, 1)
        XCTAssertEqual(model.archivedRaceCount, 12)
        XCTAssertEqual(model.uploadedTipCount, 1, "uploaded history is labelled, not hidden")
    }

    @MainActor
    func test_theRecordDefaultsToActiveAndCanSelectAnEarlierWeightSet() async throws {
        let record = ServerRecord.fixture(
            weightsInUse: ["v2": 2, "v3": 4],
            activeWeightsID: "v3")
        let server = FakeRacesServer(record: .success(record))
        let model = RecordViewModel(link: ServerLink(server: server), store: nil)

        await model.load()
        XCTAssertEqual(model.selectedWeightsID, "v3")
        XCTAssertEqual(server.recordRequests, [nil])

        await model.selectWeights("v2")
        XCTAssertEqual(model.selectedWeightsID, "v2")
        XCTAssertEqual(server.recordRequests, [nil, "v2"])
    }

    @MainActor
    func test_refreshAsksTheServerToCollectResults() async throws {
        let server = FakeRacesServer(record: .success(.fixture()))
        let model = RecordViewModel(link: ServerLink(server: server), store: nil)

        await model.refresh()

        XCTAssertEqual(server.jobs, ["results"])
        XCTAssertFalse(model.isRefreshingResults)
    }

    @MainActor
    func test_anUnreachableServerShowsTheLastSavedRecordAndSaysSo() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        let server = FakeRacesServer(record: .success(.fixture(tips: [tip("a", outcome: .won(betfairSP: 4))])))
        let moment = Date(timeIntervalSince1970: 5_000)
        let model = RecordViewModel(link: ServerLink(server: server), store: store, now: { moment })
        await model.load()

        server.setRecord(.failure(.offline))
        await model.load()

        XCTAssertEqual(try XCTUnwrap(model.state.value).wins, 1)
        XCTAssertEqual(model.staleSince, moment)
    }

    @MainActor
    func test_noServerAndNothingSavedFails() async {
        let model = RecordViewModel(link: ServerLink(server: nil, unavailable: .notConfigured(provider: "The Races server")), store: nil)

        await model.load()

        guard case .failed(let error) = model.state else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.isExpectedLimitation)
    }
}
