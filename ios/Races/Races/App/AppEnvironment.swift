import Foundation
import RacesKit

/// One transport for the whole app, so every request shares a URLSession.
private nonisolated enum SharedTransport {
    static let instance: any HTTPPerforming = URLSessionTransport()
}

/// The only place that decides whether the server exists.
///
/// The app no longer talks to The Racing API or Betfair: the Races server on
/// the homelab does, and holds those credentials in Ansible Vault. What the
/// app keeps in the Keychain is the server's address and its API token.
@Observable
@MainActor
final class AppEnvironment {

    private let credentials: any CredentialsStoring
    private let makeServer: (ServerConfiguration) -> any RacesServing

    /// Last-known responses on disk, and the history a device collected
    /// before the server existed.
    let store: RacesStore
    let history: LegacyHistory

    private(set) var configuration: ServerConfiguration?
    private(set) var credentialsFailure: APIError?
    private(set) var hasAnyStoredCredential = false

    /// Long-lived, and the server inside it is swapped by `refresh()` rather
    /// than the link being replaced.
    ///
    /// A view model captures its dependencies when SwiftUI builds it and
    /// `@State` keeps it alive across a credential change, so handing screens
    /// a *new* object would leave them talking to the old server until a
    /// relaunch. The old `MarketLoader` learned this first; the link is the same fix.
    let link: ServerLink
    let racecards: RacecardLoader

    init(
        credentials: any CredentialsStoring,
        store: RacesStore? = nil,
        history: LegacyHistory = .applicationSupport(),
        makeServer: ((ServerConfiguration) -> any RacesServing)? = nil
    ) {
        self.credentials = credentials
        let store = store ?? RacesStore(documents: AppEnvironment.makeDocumentStore())
        self.store = store
        self.history = history
        self.makeServer = makeServer ?? { configuration in
            RacesServerClient(configuration: configuration, transport: SharedTransport.instance)
        }
        let link = ServerLink(server: nil, unavailable: nil)
        self.link = link
        self.racecards = RacecardLoader(link: link, store: store)
        refresh()
    }

    /// Re-read the Keychain and rebuild the client.
    func refresh() {
        do {
            if let configuration = try ServerConfiguration(reading: credentials) {
                self.configuration = configuration
                self.credentialsFailure = nil
                link.use(server: makeServer(configuration), unavailable: nil)
            } else {
                self.configuration = nil
                self.credentialsFailure = nil
                link.use(server: nil, unavailable: .notConfigured(provider: "The Races server"))
            }
        } catch {
            let failure = APIError.from(error)
            self.configuration = nil
            self.credentialsFailure = failure
            link.use(server: nil, unavailable: failure)
        }
        hasAnyStoredCredential = CredentialSlot.allCases.contains { slot in
            (try? credentials.read(slot))?.isEmpty == false
        }
    }

    func write(_ value: String?, to slot: CredentialSlot) throws {
        try credentials.write(value, to: slot)
        refresh()
    }

    func read(_ slot: CredentialSlot) throws -> String? {
        try credentials.read(slot)
    }

    func removeAllCredentials() throws {
        try credentials.removeAll()
        refresh()
    }

    /// Why there is no server, or nil when there is one.
    var unavailabilityReason: APIError? { link.unavailable }

    var server: (any RacesServing)? { link.server }

    private static func makeDocumentStore() -> any DocumentStoring {
        do {
            return try JSONFileStore.applicationSupport(subdirectory: "Races/Cache")
        } catch {
            return InMemoryDocumentStore()
        }
    }
}

/// The server, or why there isn't one — held in one long-lived object so every
/// screen sees a credential change at once.
@MainActor
final class ServerLink {
    private(set) var server: (any RacesServing)?
    private(set) var unavailable: APIError?

    init(server: (any RacesServing)?, unavailable: APIError? = nil) {
        self.server = server
        self.unavailable = unavailable
    }

    func use(server: (any RacesServing)?, unavailable: APIError?) {
        self.server = server
        self.unavailable = unavailable
    }

    /// The server, or the reason there is none, as an error a screen can show.
    func require() throws -> any RacesServing {
        if let server { return server }
        throw unavailable ?? APIError.notConfigured(provider: "The Races server")
    }
}
