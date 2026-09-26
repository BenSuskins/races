import Foundation
import RacesKit

/// The accuracy record, as the server computes it over every tip it holds.
@Observable
@MainActor
final class RecordViewModel {

    private(set) var state: ViewState<AccuracyReport> = .idle
    private(set) var recentTips: [TipRecord] = []
    private(set) var archivedRaceCount = 0
    private(set) var isRefreshingResults = false
    /// Tips by where they came from: `server`, or `device:<name>` for history
    /// uploaded from a phone.
    private(set) var sources: [String: Int] = [:]
    private(set) var weightsInUse: [String: Int] = [:]
    private(set) var activeWeightsID: String?
    private(set) var selectedWeightsID: String?
    /// Non-nil when the record on screen is the last one saved on the phone.
    private(set) var staleSince: Date?

    private let link: ServerLink
    private let store: RacesStore?
    private let now: () -> Date

    init(link: ServerLink, store: RacesStore?, now: @escaping () -> Date = Date.init) {
        self.link = link
        self.store = store
        self.now = now
    }

    convenience init(environment: AppEnvironment) {
        self.init(link: environment.link, store: environment.store)
    }

    func loadIfNeeded() async {
        guard state.value == nil else { return }
        await load()
    }

    func load() async {
        if state.value == nil { state = .loading }
        do {
            let record = try await link.require().record(weightsID: selectedWeightsID)
            apply(record)
            staleSince = nil
            if let store { await store.saveRecord(record) }
        } catch {
            // Unwrap before the call: optional-chaining an async call is the
            // double-optional gotcha in CLAUDE.md.
            var cached: ServerRecord?
            if let store { cached = await store.cachedRecord() }
            if let cached {
                apply(cached)
                staleSince = now()
            } else {
                state = .failed(.from(error))
            }
        }
    }

    private func apply(_ record: ServerRecord) {
        state = .loaded(record.report)
        recentTips = (record.recentTips ?? []).filter { $0.outcome?.isSettled == true }
        archivedRaceCount = record.archivedRaces
        sources = record.sources
        weightsInUse = record.weightsInUse
        activeWeightsID = record.activeWeightsID
        if selectedWeightsID == nil { selectedWeightsID = record.weightsID ?? record.activeWeightsID }
    }

    func selectWeights(_ weightsID: String) async {
        selectedWeightsID = weightsID
        state = .loading
        await load()
    }

    /// Ask the server to collect results now rather than at its next quarter
    /// hour, then reload.
    func refresh() async {
        isRefreshingResults = true
        if let server = link.server {
            try? await server.runJob("results")
        }
        isRefreshingResults = false
        await load()
    }

    /// How many tips came from a phone's history rather than the server.
    var uploadedTipCount: Int {
        sources.filter { $0.key.hasPrefix("device:") }.reduce(0) { $0 + $1.value }
    }
}
