import Foundation

/// Somewhere to keep a Codable document.
///
/// A protocol rather than a concrete file store, so the tracking tests run
/// entirely in memory: no temp directories, no cleanup, and no ordering
/// surprises when tests run in parallel.
public protocol DocumentStoring: Sendable {
    func load<T: Codable & Sendable>(_ type: T.Type, from name: String) async throws -> T?
    func save<T: Codable & Sendable>(_ value: T, to name: String) async throws
    func delete(_ name: String) async throws
}

/// What actually goes on disk: the payload plus the schema version that wrote it.
///
/// Without the version, the first incompatible change to `TipRecord` would make
/// every stored tip undecodable, and the app would either crash on launch or
/// silently lose the accuracy history. With it, an unrecognised version reads as
/// "nothing stored yet" — which loses that file, but keeps the app working.
struct StoredDocument<T: Codable>: Codable {
    static var currentVersion: Int { 1 }

    let schemaVersion: Int
    let savedAt: Date
    let payload: T

    init(payload: T, savedAt: Date = Date()) {
        self.schemaVersion = Self.currentVersion
        self.savedAt = savedAt
        self.payload = payload
    }
}

enum StoreCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Codable JSON on disk, one file per document.
public actor JSONFileStore: DocumentStoring {

    public enum StoreError: Error, CustomStringConvertible {
        case unusableDirectory(String)

        public var description: String {
            switch self {
            case .unusableDirectory(let path):
                return "Couldn't use the storage directory at \(path)."
            }
        }
    }

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Application Support, so the tips ledger and results archive persist.
    ///
    /// Deliberately **not** Caches: iOS may evict that whenever it likes, and
    /// losing part of the accuracy history would quietly bias every figure the
    /// app reports — a silently truncated record looks exactly like a real one.
    public static func applicationSupport(
        subdirectory: String = "Races",
        fileManager: FileManager = .default
    ) throws -> JSONFileStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return JSONFileStore(
            directory: base.appendingPathComponent(subdirectory),
            fileManager: fileManager
        )
    }

    public func load<T: Codable & Sendable>(_ type: T.Type, from name: String) async throws -> T? {
        let fileURL = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let data = try Data(contentsOf: fileURL)

        // A document written by a newer build, or corrupted on disk, reads as
        // absent rather than throwing. Losing one file's history is bad; being
        // unable to open the app because of it is worse.
        guard let envelope = try? StoreCoding.makeDecoder().decode(StoredDocument<T>.self, from: data),
              envelope.schemaVersion == StoredDocument<T>.currentVersion else {
            return nil
        }
        return envelope.payload
    }

    public func save<T: Codable & Sendable>(_ value: T, to name: String) async throws {
        try ensureDirectory()
        let data = try StoreCoding.makeEncoder().encode(StoredDocument(payload: value))

        // Atomic, so a crash mid-write cannot leave half a file behind. Killing
        // the app during a reconcile is a routine thing to do, not an edge case.
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    public func delete(_ name: String) async throws {
        let fileURL = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw StoreError.unusableDirectory(directory.path)
            }
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// An in-memory store for tests and previews. Round-trips through JSON like the
/// real one, so a type that fails to encode fails here too.
public actor InMemoryDocumentStore: DocumentStoring {
    private var documents: [String: Data] = [:]

    public init() {}

    public func load<T: Codable & Sendable>(_ type: T.Type, from name: String) async throws -> T? {
        guard let data = documents[name] else { return nil }
        guard let envelope = try? StoreCoding.makeDecoder().decode(StoredDocument<T>.self, from: data),
              envelope.schemaVersion == StoredDocument<T>.currentVersion else {
            return nil
        }
        return envelope.payload
    }

    public func save<T: Codable & Sendable>(_ value: T, to name: String) async throws {
        documents[name] = try StoreCoding.makeEncoder().encode(StoredDocument(payload: value))
    }

    public func delete(_ name: String) async throws {
        documents[name] = nil
    }

    public var storedNames: [String] {
        documents.keys.sorted()
    }

    /// Plant a document written by a future build, to prove that an unreadable
    /// file degrades to "nothing stored" rather than taking the app down.
    public func plantRawDocument(_ json: String, as name: String) {
        documents[name] = Data(json.utf8)
    }
}
