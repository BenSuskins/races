import Foundation
import RacesKit

/// How the tips have actually done.
///
/// The report is computed from the ledger, never stored, so it cannot drift from
/// the tips it describes. Opening this tab also runs a results pass, because this
/// is the screen a user opens in the evening — exactly when today's results are
/// still available and about to stop being.
@Observable
@MainActor
final class RecordViewModel {

    private(set) var state: ViewState<AccuracyReport> = .idle
    private(set) var archivedRaceCount = 0
    private(set) var isRefreshingResults = false
    /// What the last results pass changed, for a one-line confirmation.
    private(set) var lastIngestion: ResultsIngestion?

    private let environment: AppEnvironment?
    private let store: RacesStore?

    init(environment: AppEnvironment?, store: RacesStore?) {
        self.environment = environment
        self.store = store
    }

    convenience init(environment: AppEnvironment) {
        self.init(environment: environment, store: environment.store)
    }

    func loadIfNeeded() async {
        guard state.value == nil else { return }
        await load()
    }

    /// Show the record from what is already on disk.
    func load() async {
        guard let store else {
            state = .failed(.notConfigured(provider: "The Racing API"))
            return
        }
        await store.loadIfNeeded()
        state = .loaded(await store.report())
        archivedRaceCount = await store.archivedRaceCount
    }

    /// Fetch today's results, then recompute.
    ///
    /// Deliberately never fails the screen: an unreachable provider does not
    /// invalidate the record already on disk, and the report itself displays
    /// coverage so an incomplete record cannot pass as a complete one.
    func refresh() async {
        isRefreshingResults = true
        if let environment {
            // Not `await environment?.refreshResults()`: optional-chaining an
            // async call yields a double optional, which will not assign here.
            lastIngestion = await environment.refreshResults()
        }
        isRefreshingResults = false
        await load()
    }

    func clearHistory() async {
        guard let store else { return }
        await store.clearHistory()
        lastIngestion = nil
        await load()
    }
}
