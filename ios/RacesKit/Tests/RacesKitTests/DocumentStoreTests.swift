import XCTest
@testable import RacesKit

private struct Payload: Codable, Hashable, Sendable {
    let name: String
    let count: Int
    let when: Date
}

final class DocumentStoreTests: XCTestCase {

    private let sample = Payload(
        name: "Ascot", count: 7, when: Date(timeIntervalSince1970: 1_800_000_000)
    )

    // MARK: - In-memory

    func test_savesAndLoads() async throws {
        let store = InMemoryDocumentStore()
        try await store.save(sample, to: "tips.json")

        let loaded = try await store.load(Payload.self, from: "tips.json")

        XCTAssertEqual(loaded, sample)
    }

    func test_loadingSomethingNeverSavedIsNilNotAnError() async throws {
        let store = InMemoryDocumentStore()
        let loaded = try await store.load(Payload.self, from: "missing.json")
        XCTAssertNil(loaded)
    }

    func test_delete() async throws {
        let store = InMemoryDocumentStore()
        try await store.save(sample, to: "tips.json")
        try await store.delete("tips.json")

        XCTAssertNil(try await store.load(Payload.self, from: "tips.json"))
        try await store.delete("tips.json")  // deleting twice is fine
    }

    /// A file written by a newer build reads as "nothing stored" rather than
    /// throwing. Losing one file's history is bad; being unable to open the app
    /// because of it is worse.
    func test_aDocumentFromAFutureBuildDegradesToNothing() async throws {
        let store = InMemoryDocumentStore()
        await store.plantRawDocument(
            #"{"schemaVersion":999,"savedAt":"2026-09-20T00:00:00Z","payload":{"name":"Ascot","count":7,"when":"2027-01-15T00:00:00Z"}}"#,
            as: "tips.json"
        )

        XCTAssertNil(try await store.load(Payload.self, from: "tips.json"))
    }

    func test_aCorruptedDocumentDegradesToNothing() async throws {
        let store = InMemoryDocumentStore()
        await store.plantRawDocument("{ this is not json", as: "tips.json")

        XCTAssertNil(try await store.load(Payload.self, from: "tips.json"))
    }

    // MARK: - On disk

    func test_fileStoreRoundTripsThroughTheFileSystem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("races-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONFileStore(directory: directory)
        try await store.save(sample, to: "tips.json")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("tips.json").path),
            "the directory should have been created on demand"
        )
        XCTAssertEqual(try await store.load(Payload.self, from: "tips.json"), sample)
    }

    func test_fileStoreOverwritesCleanly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("races-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONFileStore(directory: directory)
        try await store.save(sample, to: "tips.json")
        try await store.save(Payload(name: "York", count: 1, when: sample.when), to: "tips.json")

        XCTAssertEqual(try await store.load(Payload.self, from: "tips.json")?.name, "York")
    }

    func test_fileStoreLoadOfAMissingFileIsNil() async throws {
        let store = JSONFileStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("races-tests-\(UUID().uuidString)")
        )
        XCTAssertNil(try await store.load(Payload.self, from: "nothing.json"))
    }

    /// The ledger and the archive are what the accuracy figures are built from,
    /// so they have to survive a round trip exactly.
    func test_theTypesWeActuallyStoreRoundTrip() async throws {
        let store = InMemoryDocumentStore()

        let ledger = TipLedger(tips: [.make(outcome: .won(betfairSP: 4.2))])
        try await store.save(ledger, to: "tips.json")
        let restoredLedger = try await store.load(TipLedger.self, from: "tips.json")
        XCTAssertEqual(restoredLedger?.tip(forRace: "rac_1")?.outcome, .won(betfairSP: 4.2))

        var archive = ResultsArchive()
        archive.ingest(TestResult.result(
            finishing: [("hrs_1", "1"), ("hrs_2", "2"), ("hrs_3", "3")],
            jockeys: ["hrs_1": "jky_1"]
        ))
        try await store.save(archive, to: "archive.json")
        let restoredArchive = try await store.load(ResultsArchive.self, from: "archive.json")
        XCTAssertEqual(restoredArchive?.jockeyStrikeRate(id: "jky_1"), StrikeRate(runs: 1, wins: 1))
    }
}
