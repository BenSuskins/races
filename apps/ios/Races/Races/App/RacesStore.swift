import Foundation
import RacesKit

/// Document names. At file scope and `nonisolated`, not nested in the actor:
/// a nested type picks up the app target's MainActor default, and the actor's
/// own methods could not read it.
nonisolated enum StoreDocument {
    static func racecard(day: String) -> String { "racecard-\(day).json" }
    static let record = "record.json"
}

/// The last responses the server gave, on disk.
///
/// The server holds the history now; this is only so a phone with no signal
/// still opens on the card it last saw, clearly marked as such, rather than on
/// an error. Nothing here is authoritative and nothing is ever written back.
///
/// An `actor` because persistence is async; one actor so two screens saving at
/// once cannot interleave.
actor RacesStore {

    private let documents: any DocumentStoring

    init(documents: any DocumentStoring) {
        self.documents = documents
    }

    func cachedRacecard(day: String) async -> ServerRacecard? {
        try? await documents.load(ServerRacecard.self, from: StoreDocument.racecard(day: day))
    }

    func saveRacecard(_ card: ServerRacecard, day: String) async {
        try? await documents.save(card, to: StoreDocument.racecard(day: day))
    }

    func cachedRecord() async -> ServerRecord? {
        try? await documents.load(ServerRecord.self, from: StoreDocument.record)
    }

    func saveRecord(_ record: ServerRecord) async {
        try? await documents.save(record, to: StoreDocument.record)
    }
}

/// The history a phone collected before the server existed.
///
/// Before the server, `RacesStore` kept the tip ledger, the results archive
/// and the on-device training state as JSON documents in Application Support.
/// Those are the only copies of every race day this phone saw, and the free
/// results endpoint cannot rebuild them. Settings uploads them once; the files
/// are read, never modified, and a marker records the upload so the button
/// does not keep offering itself.
nonisolated struct LegacyHistory: Sendable {
    static let tips = "tips.json"
    static let archive = "archive.json"
    static let training = "training.json"
    static let uploadedMarker = "uploaded-to-server.json"

    /// Where the documents live, or nil if Application Support is unreachable.
    let directory: URL?

    init(directory: URL?) {
        self.directory = directory
    }

    /// `Application Support/Races`, where `JSONFileStore.applicationSupport()`
    /// wrote them.
    static func applicationSupport(fileManager: FileManager = .default) -> LegacyHistory {
        let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false)
        return LegacyHistory(directory: base?.appendingPathComponent("Races"))
    }

    private func read(_ name: String) -> Data? {
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// The documents, as the upload carries them.
    func upload(device: String) -> ServerHistoryUpload {
        ServerHistoryUpload(
            device: device,
            tips: read(Self.tips),
            archive: read(Self.archive),
            training: read(Self.training))
    }

    /// Whether there is anything to upload at all.
    var exists: Bool { !upload(device: "").isEmpty }

    /// When the history was uploaded, if it has been.
    var uploadedAt: Date? {
        guard let data = read(Self.uploadedMarker) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Marker.self, from: data).uploadedAt
    }

    func markUploaded(at date: Date = Date()) throws {
        guard let directory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Marker(uploadedAt: date))
        try data.write(to: directory.appendingPathComponent(Self.uploadedMarker), options: .atomic)
    }

    private nonisolated struct Marker: Codable {
        let uploadedAt: Date
    }
}
