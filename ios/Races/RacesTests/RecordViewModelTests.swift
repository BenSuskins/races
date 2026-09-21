import XCTest
@testable import Races
import RacesKit

/// `@MainActor async` throughout — see the gotcha in CLAUDE.md.
final class RecordViewModelTests: XCTestCase {

    @MainActor
    func test_anEmptyLedgerReportsZeroRatherThanFailing() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        let model = RecordViewModel(environment: nil, store: store)

        await model.load()

        let report = try XCTUnwrap(model.state.value)
        XCTAssertEqual(report.total, 0)
        XCTAssertNil(report.strikeRate)
    }

    @MainActor
    func test_theReportReflectsSettledTips() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        let offAt = Date(timeIntervalSince1970: 10_000)
        let race = Race(
            id: "rac_1", courseName: "Ascot", name: "A Race", offTime: "2:30",
            offDateTime: offAt, date: "2026-06-16",
            runners: [.fixture(id: "a", officialRating: 100),
                      .fixture(id: "b", officialRating: 50)])

        await store.assessAndRecord([race], now: offAt.addingTimeInterval(-3_600))
        let recorded = await store.tip(forRace: "rac_1")
        let tip = try XCTUnwrap(recorded)
        await store.ingest(
            results: [.fixture(id: "rac_1", finishers: [
                .fixture(horseID: tip.selectionHorseID, position: 1),
            ])],
            now: offAt.addingTimeInterval(600))

        let model = RecordViewModel(environment: nil, store: store)
        await model.load()

        let report = try XCTUnwrap(model.state.value)
        XCTAssertEqual(report.settled, 1)
        XCTAssertEqual(report.wins, 1)
        XCTAssertEqual(report.strikeRate, 1.0)
    }

    @MainActor
    func test_roiIsWithheldBelowTheMinimumSample() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        let model = RecordViewModel(environment: nil, store: store)

        await model.load()

        // Level-stakes ROI over a handful of bets is noise, and showing it would
        // invite exactly the wrong conclusion.
        let report = try XCTUnwrap(model.state.value)
        XCTAssertFalse(report.isSufficientSampleForROI)
    }

    @MainActor
    func test_noStoreReportsAnExpectedLimitation() async {
        let model = RecordViewModel(environment: nil, store: nil)

        await model.load()

        guard case .failed(let error) = model.state else {
            return XCTFail("Expected a failed state, got \(model.state)")
        }
        XCTAssertTrue(error.isExpectedLimitation)
    }

    @MainActor
    func test_clearingHistoryEmptiesTheReport() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.assessAndRecord([
            Race.fixture(runners: [.fixture(id: "a"), .fixture(id: "b")]),
        ])
        let model = RecordViewModel(environment: nil, store: store)
        await model.load()
        XCTAssertEqual(try XCTUnwrap(model.state.value).total, 1)

        await model.clearHistory()

        let report = try XCTUnwrap(model.state.value)
        XCTAssertEqual(report.total, 0)
    }

    @MainActor
    func test_theArchiveCountIsSurfaced() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.ingest(results: [
            .fixture(id: "r1", finishers: [.fixture(horseID: "a", position: 1)]),
            .fixture(id: "r2", finishers: [.fixture(horseID: "b", position: 1)]),
        ])
        let model = RecordViewModel(environment: nil, store: store)

        await model.load()

        XCTAssertEqual(model.archivedRaceCount, 2)
    }
}
