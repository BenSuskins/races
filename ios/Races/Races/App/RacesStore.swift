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
