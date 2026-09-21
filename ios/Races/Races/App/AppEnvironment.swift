import Foundation
import RacesKit

/// One transport for the process, not one per rebuild: `URLSession` pools
/// connections, and a fresh session on every credential save would throw that away.
///
/// It lives in a `nonisolated` namespace rather than as a static on
/// `AppEnvironment`, because a static on a `@MainActor` type is itself
/// main-actor-isolated — and the provider-building closure that reads it is
/// nonisolated, so that would not compile.
private nonisolated enum SharedTransport {
    static let instance: any HTTPPerforming = URLSessionTransport()
}

/// Owns the one mutable thing the whole app depends on: whether we have working
/// credentials, and therefore whether there is a provider to call.
///
/// It exists so that "not configured" is resolved in exactly one place. Every
/// view model takes an optional provider and reports
/// `APIError.notConfigured` when it is absent, which `ErrorStateView` renders as
/// information rather than as a fault.
///
/// `makeRacingProvider` is injected so tests can drive the whole UI from a fake
/// without a Keychain, a network or a subscription.
@Observable
@MainActor
final class AppEnvironment {

    private let credentials: any CredentialsStoring
    private let makeRacingProvider: (ProviderConfiguration.RacingAPI) -> any RacingDataProviding

    /// Persistence, the tip ledger, the results archive and the rater.
    let store: RacesStore


    private(set) var configuration: ProviderConfiguration?
    /// Non-nil when the Keychain itself failed.
    ///
    /// Deliberately distinct from "nothing stored". Reading a broken Keychain as
    /// empty would tell the user to enter credentials they have already given us,
    /// and they'd have no way to tell that re-entering them cannot work.
    private(set) var credentialsFailure: APIError?
    private(set) var racingProvider: (any RacingDataProviding)?

    init(
        credentials: any CredentialsStoring,
        store: RacesStore? = nil,
        makeRacingProvider: ((ProviderConfiguration.RacingAPI) -> any RacingDataProviding)? = nil
    ) {
        self.credentials = credentials
        self.store = store ?? RacesStore(documents: AppEnvironment.makeDocumentStore())
        self.makeRacingProvider = makeRacingProvider ?? { racingAPI in
            RacingAPIClient(
                credentials: RacingAPICredentials(
                    username: racingAPI.username,
                    password: racingAPI.password),
                transport: SharedTransport.instance)
        }
        refresh()
    }

    /// Re-read the Keychain and rebuild the provider. Called at launch and after
    /// Settings writes, so a newly entered key takes effect without a relaunch.
    func refresh() {
        do {
            let configuration = try ProviderConfiguration(reading: credentials)
            self.configuration = configuration
            self.credentialsFailure = nil
            if let racingAPI = configuration.racingAPI {
                self.racingProvider = makeRacingProvider(racingAPI)
            } else {
                self.racingProvider = nil
            }
        } catch {
            self.configuration = nil
            self.credentialsFailure = .from(error)
            self.racingProvider = nil
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

    /// The error a screen should show when it has nothing to call.
    ///
    /// A broken Keychain outranks a missing key: if we cannot read the store, the
    /// user's credentials may well be there, and telling them to add some would be
    /// wrong as well as unhelpful.
    var unavailabilityReason: APIError? {
        if let credentialsFailure { return credentialsFailure }
        if racingProvider == nil { return .notConfigured(provider: "The Racing API") }
        return nil
    }

    /// Application Support, falling back to memory.
    ///
    /// If the directory cannot be created there is nothing the user can do, and
    /// running without history beats refusing to launch — but the fallback is
    /// in-memory rather than Caches, because iOS may evict Caches whenever it
    /// likes and a silently truncated accuracy record looks exactly like a real
    /// one.
    private static func makeDocumentStore() -> any DocumentStoring {
        do {
            return try JSONFileStore.applicationSupport()
        } catch {
            return InMemoryDocumentStore()
        }
    }

    /// A loader bound to the current provider and store.
    ///
    /// Made per screen rather than held, so that re-entering a tab after saving
    /// credentials picks up the new provider without any invalidation dance.
    func makeRacecardLoader() -> RacecardLoader {
        RacecardLoader(provider: racingProvider, store: store)
    }

    /// Fetch today's results, archive them, and settle whatever they answer.
    ///
    /// The single path for this, shared by launch, the Record tab and the
    /// background task. It matters that it is one path: the free results endpoint
    /// covers **today only**, so a day the app never runs this is a day of
    /// results gone for good, and a second implementation is a second thing that
    /// can quietly stop working.
    @discardableResult
    func refreshResults(now: Date = Date()) async -> ResultsIngestion? {
        await store.loadIfNeeded()
        guard let provider = racingProvider else { return nil }

        do {
            let results = try await provider.results(day: .today)
            return await store.ingest(results: results, now: now)
        } catch {
            // Never surfaced as an error: a provider that cannot give results
            // right now is not a fault the user can act on, and the tips it would
            // have settled stay pending until they expire, which the report
            // counts and displays.
            return nil
        }
    }
}
