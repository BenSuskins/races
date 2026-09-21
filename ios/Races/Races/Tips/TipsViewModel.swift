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

    private(set) var state: ViewState<[Selection]> = .idle
    private(set) var archivedRaceCount = 0

    private let loader: RacecardLoader?
    private let store: RacesStore?
    private let unavailable: APIError?
    private let now: () -> Date

    init(
        loader: RacecardLoader?,
        store: RacesStore?,
        unavailable: APIError?,
        now: @escaping () -> Date = Date.init
    ) {
        self.loader = loader
        self.store = store
        self.unavailable = unavailable
        self.now = now
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            loader: environment.makeRacecardLoader(),
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

            let upcoming = load.races.filter { !$0.hasStarted }
            let assessments = await store.assessAndRecord(upcoming, now: moment)

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
        } catch {
            state = .failed(.from(error))
        }
    }

    private static func byOffTime(_ lhs: Race, _ rhs: Race) -> Bool {
        (lhs.offDateTime ?? .distantFuture) < (rhs.offDateTime ?? .distantFuture)
    }
}
