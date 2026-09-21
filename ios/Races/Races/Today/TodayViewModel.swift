import Foundation
import RacesKit

/// Today's racing, grouped into meetings.
///
/// Holds a freshness window because the Racing API's free tier is paced at one
/// request a second and a tab switch is not new information. Non-runners come out
/// through the afternoon, so the window is short rather than absent, and pull to
/// refresh always bypasses it.
@Observable
@MainActor
final class TodayViewModel {

    /// Long enough that flicking between tabs costs nothing, short enough that
    /// withdrawals appear without the user wondering why the card looks stale.
    static let freshness: TimeInterval = 15 * 60

    private(set) var state: ViewState<[Meeting]> = .idle

    private let provider: (any RacingDataProviding)?
    private let unavailable: APIError?
    private let now: () -> Date
    private var loadedAt: Date?

    init(
        provider: (any RacingDataProviding)?,
        unavailable: APIError?,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.unavailable = unavailable
        self.now = now
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            provider: environment.racingProvider,
            unavailable: environment.unavailabilityReason)
    }

    var isStale: Bool {
        guard let loadedAt else { return true }
        return now().timeIntervalSince(loadedAt) >= Self.freshness
    }

    func loadIfNeeded() async {
        guard isStale || state.value == nil else { return }
        await load()
    }

    func load() async {
        if let unavailable {
            state = .failed(unavailable)
            return
        }
        guard let provider else {
            state = .failed(.notConfigured(provider: "The Racing API"))
            return
        }

        // Keep the existing card on screen while refreshing; a spinner over
        // content the user is already reading is a regression, not feedback.
        if state.value == nil {
            state = .loading
        }

        do {
            let races = try await provider.racecards(
                day: .today, regionCodes: BrowseRegions.codes)
            state = .loaded(races.groupedIntoMeetings())
            loadedAt = now()
        } catch {
            state = .failed(.from(error))
            loadedAt = nil
        }
    }
}
