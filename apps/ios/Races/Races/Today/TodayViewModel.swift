import Foundation
import RacesKit

/// A day's racing, grouped into meetings.
///
/// Reads through `RacecardLoader`, so a tab switch costs no request and a
/// phone off the tailnet still opens on the last card it saw.
@Observable
@MainActor
final class TodayViewModel {

    private(set) var state: ViewState<[Meeting]> = .idle
    /// Non-nil when the card on screen came from disk after a failed refresh.
    private(set) var staleSince: Date?

    private(set) var day: RaceDay = .today

    /// Switching day is an explicit await rather than a `didSet` that spawns a
    /// `Task`: the implicit version is untestable without sleeping, and two rapid
    /// taps could land their results out of order.
    func select(_ day: RaceDay) async {
        guard day != self.day else { return }
        self.day = day
        state = .idle
        staleSince = nil
        await load()
    }

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
        do {
            let load = try await loader.load(day: day, forceRefresh: forceRefresh, now: now())
            state = .loaded(load.races.groupedIntoMeetings())
            staleSince = load.servedStaleAfterFailure ? load.fetchedAt : nil
        } catch {
            state = .failed(.from(error))
            staleSince = nil
        }
    }
}
