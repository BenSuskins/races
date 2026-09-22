import Foundation
import RacesKit

/// Today's selections, one per race.
///
/// Assessing and recording happen together and on every refresh, which is what
/// the sealing rule needs: a tip is a draft that keeps being revised until five
/// minutes before the off, and then the last draft becomes the record. A screen
/// that only assessed on first open would seal whatever the card looked like that
/// morning.
///
/// Races that have already run are dropped rather than rated. `TipLedger` would
/// refuse to record them anyway, and showing a selection for a finished race
/// invites reading it as a tip that was never given.
@Observable
@MainActor
final class TipsViewModel {

    nonisolated struct Selection: Identifiable, Hashable, Sendable {
        let race: Race
        let assessment: RaceAssessment
        /// Whether this one is now immutable.
        let isSealed: Bool

        var id: String { race.id }
        var selection: RunnerAssessment? { assessment.selection }
    }

    /// How much of the card the exchange actually priced.
    ///
    /// Shown whether or not it flatters. A card where two races in twenty
    /// matched is a card where eighteen tips are form-only, and a screen that
    /// only reported the good case would make the model look better anchored
    /// than it is.
    nonisolated struct MarketCoverage: Equatable, Sendable {
        let pricedRaces: Int
        let totalRaces: Int
        /// Why there are no prices at all, when that is the situation. Absent
        /// when Betfair answered and the races simply did not match.
        let failure: APIError?

        var isComplete: Bool { totalRaces > 0 && pricedRaces == totalRaces }
        var hasAny: Bool { pricedRaces > 0 }
    }

    private(set) var state: ViewState<[Selection]> = .idle
    private(set) var archivedRaceCount = 0
    private(set) var marketCoverage: MarketCoverage?

    private let loader: RacecardLoader?
    private let markets: MarketLoader?
    private let store: RacesStore?
    private let unavailable: APIError?
    private let now: () -> Date

    init(
        loader: RacecardLoader?,
        markets: MarketLoader?,
        store: RacesStore?,
        unavailable: APIError?,
        now: @escaping () -> Date = Date.init
    ) {
        self.loader = loader
        self.markets = markets
        self.store = store
        self.unavailable = unavailable
        self.now = now
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            loader: environment.makeRacecardLoader(),
            markets: environment.marketLoader,
            store: environment.store,
            unavailable: environment.credentialsFailure)
    }

    func loadIfNeeded() async {
        guard state.value == nil else { return }
        await load()
    }

    func load(forceRefresh: Bool = false) async {
        if let unavailable {
            state = .failed(unavailable)
            return
        }
        guard let loader, let store else {
            state = .failed(.notConfigured(provider: "The Racing API"))
            return
        }

        if state.value == nil { state = .loading }
        let moment = now()

        do {
            let load = try await loader.load(day: .today, forceRefresh: forceRefresh, now: moment)
            await store.loadIfNeeded()

            let upcoming = load.races.filter { !Self.hasStarted($0, by: moment) }

            // Prices first, then one assess-and-record pass over the whole card.
            // Recording is what seals a tip, so the market has to be in hand
            // before it happens — a tip sealed form-only and re-rated with
            // prices afterwards would be a record of something we never showed.
            let market = await markets?.load(
                races: upcoming, day: .today, forceRefresh: forceRefresh, now: moment)
            let snapshots = market?.snapshots ?? [:]

            let assessments = await store.assessAndRecord(
                upcoming, markets: snapshots, now: moment)

            var selections: [Selection] = []
            for race in upcoming.sorted(by: Self.byOffTime) {
                guard let assessment = assessments[race.id],
                      assessment.selection != nil else { continue }
                let sealed = await store.tip(forRace: race.id)?.isSealed ?? false
                selections.append(
                    Selection(race: race, assessment: assessment, isSealed: sealed))
            }

            state = .loaded(selections)
            archivedRaceCount = await store.archivedRaceCount
            marketCoverage = MarketCoverage(
                pricedRaces: snapshots.count,
                totalRaces: upcoming.count,
                failure: market?.failure)
        } catch {
            state = .failed(.from(error))
        }
    }

    private static func byOffTime(_ lhs: Race, _ rhs: Race) -> Bool {
        (lhs.offDateTime ?? .distantFuture) < (rhs.offDateTime ?? .distantFuture)
    }

    /// Deliberately not `Race.hasStarted`, which reads the real `Date()`.
    ///
    /// This screen decides what to rate and what to record, and both must be
    /// judged against the same instant the tip is stamped with — otherwise the
    /// filter and the sealing rule can disagree. It also made the view model
    /// untestable: it accepted an injected clock and then ignored it for the one
    /// decision that mattered, so every fixture race read as already run.
    ///
    /// A race with no known off time is treated as still to come, matching the
    /// kit, and `TipLedger` seals it on first write.
    private static func hasStarted(_ race: Race, by moment: Date) -> Bool {
        guard let offDateTime = race.offDateTime else { return false }
        return offDateTime < moment
    }
}
