import Foundation
import RacesKit

/// The model's selection for every race still to run today.
///
/// The server rates the whole card and seals each tip five minutes before the
/// off whether or not a phone is looking, so this screen only reads. It used to
/// record — and had to fetch prices first, and had to record the whole card
/// rather than the races that looked interesting — and all of that now happens
/// in one place, on the server, on a clock.
@Observable
@MainActor
final class TipsViewModel {

    nonisolated struct Selection: Identifiable, Hashable, Sendable {
        let race: Race
        let assessment: RaceAssessment
        let isSealed: Bool

        var id: String { race.id }
        var selection: RunnerAssessment? { assessment.selection }
    }

    /// How much of the card is anchored to the market. "Matched a market" and
    /// "has prices" are different claims; this counts the second.
    nonisolated struct MarketCoverage: Equatable, Sendable {
        let pricedRaces: Int
        let totalRaces: Int

        var isComplete: Bool { totalRaces > 0 && pricedRaces == totalRaces }
        var hasAny: Bool { pricedRaces > 0 }
    }

    private(set) var state: ViewState<[Selection]> = .idle
    private(set) var archivedRaceCount = 0
    private(set) var marketCoverage: MarketCoverage?
    /// Non-nil when the card on screen came from disk after a failed refresh.
    private(set) var staleSince: Date?

    private let loader: RacecardLoader
    private let now: () -> Date

    init(loader: RacecardLoader, now: @escaping () -> Date = Date.init) {
        self.loader = loader
        self.now = now
    }

    convenience init(environment: AppEnvironment) {
        self.init(loader: environment.racecards)
    }

    func loadIfNeeded() async {
        guard state.value == nil else { return }
        await load()
    }

    func load(forceRefresh: Bool = false) async {
        if state.value == nil { state = .loading }
        // Compare against the injected instant, never `Race.hasStarted`, which
        // reads the real clock and would make every 1970 fixture look run.
        let moment = now()
        do {
            let load = try await loader.load(day: .today, forceRefresh: forceRefresh, now: moment)
            let upcoming = load.races
                .filter { !Self.hasStarted($0, by: moment) }
                .sorted(by: Self.byOffTime)

            var selections: [Selection] = []
            var priced = 0
            for race in upcoming {
                guard let assessment = load.card.assessments[race.id],
                      assessment.selection != nil else { continue }
                if !assessment.isFormOnly { priced += 1 }
                selections.append(Selection(
                    race: race,
                    assessment: assessment,
                    isSealed: load.card.tips[race.id]?.isSealed ?? false))
            }

            state = .loaded(selections)
            archivedRaceCount = load.card.archivedRaces
            marketCoverage = MarketCoverage(pricedRaces: priced, totalRaces: upcoming.count)
            staleSince = load.servedStaleAfterFailure ? load.fetchedAt : nil
        } catch {
            state = .failed(.from(error))
            staleSince = nil
        }
    }

    private static func byOffTime(_ lhs: Race, _ rhs: Race) -> Bool {
        (lhs.offDateTime ?? .distantFuture) < (rhs.offDateTime ?? .distantFuture)
    }

    private static func hasStarted(_ race: Race, by moment: Date) -> Bool {
        guard let offDateTime = race.offDateTime else { return false }
        return offDateTime < moment
    }
}
