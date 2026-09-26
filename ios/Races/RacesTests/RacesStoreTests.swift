import XCTest
@testable import Races
import RacesKit

/// The store is only a cache now. `InMemoryDocumentStore` round-trips through
/// JSON exactly as `JSONFileStore` does.
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

}
