import XCTest
@testable import Races
import RacesKit

/// The store is only a cache now, and the legacy history is only read. Both
/// are tested against real encoding: `InMemoryDocumentStore` round-trips
/// through JSON exactly as `JSONFileStore` does, and `LegacyHistory` reads a
/// real temporary directory.
final class RacesStoreTests: XCTestCase {

    func test_aSavedCardSurvivesARelaunch() async throws {
        let documents = InMemoryDocumentStore()
        let card = ServerRacecard.fixture(races: [.fixture(id: "r1"), .fixture(id: "r2")], archivedRaces: 3)
        await RacesStore(documents: documents).saveRacecard(card, day: "2026-06-16")

        // A second store over the same documents is how a relaunch is tested.
        let restored = await RacesStore(documents: documents).cachedRacecard(day: "2026-06-16")

        XCTAssertEqual(restored, card)
        let otherDay = await RacesStore(documents: documents).cachedRacecard(day: "2026-06-17")
        XCTAssertNil(otherDay)
    }

    func test_aSavedRecordSurvivesARelaunch() async throws {
        let documents = InMemoryDocumentStore()
        let record = ServerRecord.fixture(sources: ["server": 4], archivedRaces: 9)
        await RacesStore(documents: documents).saveRecord(record)

        let restored = await RacesStore(documents: documents).cachedRecord()

        XCTAssertEqual(restored, record)
    }

    func test_legacyHistoryIsReadByteForByte() throws {
        let tips = #"{"schemaVersion":1,"savedAt":"2026-09-20T18:00:00Z","payload":{"storage":{}}}"#
        let history = try temporaryHistory(documents: [LegacyHistory.tips: tips])

        let upload = history.upload(device: "phone")

        XCTAssertTrue(history.exists)
        XCTAssertEqual(upload.tips, Data(tips.utf8))
        XCTAssertNil(upload.archive)
        XCTAssertNil(upload.training)
    }

    func test_noHistoryMeansNothingToOffer() throws {
        let history = try temporaryHistory()
        XCTAssertFalse(history.exists)
        XCTAssertFalse(LegacyHistory(directory: nil).exists)
    }

    func test_theUploadMarkerRecordsWhen() throws {
        let history = try temporaryHistory(documents: [LegacyHistory.archive: "{}"])
        XCTAssertNil(history.uploadedAt)

        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        try history.markUploaded(at: moment)

        XCTAssertEqual(history.uploadedAt, moment)
        XCTAssertTrue(history.exists, "the documents themselves are never deleted")
    }
}
