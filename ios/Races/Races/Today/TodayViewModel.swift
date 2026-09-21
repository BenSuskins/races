import Foundation
import RacesKit

/// A day's racing, grouped into meetings.
///
/// Reads through `RacecardLoader`, so the disk cache means a cold launch shows
/// the last card immediately rather than a spinner, and a tab switch costs no
/// request against the 1 req/s free tier.
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

    private let loader: RacecardLoader?
    private let unavailable: APIError?
    private let now: () -> Date

    init(
        loader: RacecardLoader?,
        unavailable: APIError?,
        now: @escaping () -> Date = Date.init
    ) {
        self.loader = loader
        self.unavailable = unavailable
        self.now = now
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            loader: environment.makeRacecardLoader(),
            unavailable: environment.credentialsFailure)
    }

    func loadIfNeeded() async {
        guard state.value == nil else { return }
        await load()
    }

    func load(forceRefresh: Bool = false) async {
        // Only a broken Keychain short-circuits. A missing key does not: the
        // cache may still hold a card worth showing, and the loader decides.
        if let unavailable {
            state = .failed(unavailable)
            return
        }
        guard let loader else {
            state = .failed(.notConfigured(provider: "The Racing API"))
            return
        }

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
