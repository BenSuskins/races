import Foundation
import RacesKit

/// A card as a screen receives it.
nonisolated struct RacecardLoad: Sendable {
    let card: ServerRacecard
    let fetchedAt: Date
    /// True when the server could not be reached and this is the last card
    /// saved on the phone.
    let servedStaleAfterFailure: Bool

    var races: [Race] { card.races }
    var isFresh: Bool { !servedStaleAfterFailure }
}

/// Reads a day's card from the server, through a short on-disk cache.
///
/// Shared by Racing and Tips so the two cannot disagree about what is running,
/// and so opening both costs one request, not two. When the server is out of
/// reach — no signal, off the tailnet — it falls back to the last card saved,
/// and says so.
@MainActor
final class RacecardLoader {

    /// Long enough that switching tabs does not refetch; short enough that a
    /// pull-to-refresh is rarely needed. The server itself refreshes every
    /// fifteen minutes, so nothing fresher exists to fetch.
    static let freshness: TimeInterval = 60

    private let link: ServerLink
    private let store: RacesStore
    private var memory: [String: RacecardLoad] = [:]

    init(link: ServerLink, store: RacesStore) {
        self.link = link
        self.store = store
    }

    func load(
        day: RaceDay,
        forceRefresh: Bool = false,
        now: Date = Date()
    ) async throws -> RacecardLoad {
        let dayString = RaceDates.dayString(for: day, now: now)

        if !forceRefresh, let recent = memory[dayString],
           recent.isFresh, now.timeIntervalSince(recent.fetchedAt) < Self.freshness {
            return recent
        }

        do {
            let server = try link.require()
            let card = try await server.racecard(day: day)
            await store.saveRacecard(card, day: dayString)
            let load = RacecardLoad(card: card, fetchedAt: now, servedStaleAfterFailure: false)
            memory[dayString] = load
            return load
        } catch {
            if let cached = await store.cachedRacecard(day: dayString) {
                return RacecardLoad(
                    card: cached,
                    fetchedAt: cached.fetchedAt ?? now,
                    servedStaleAfterFailure: true)
            }
            throw APIError.from(error)
        }
    }
}
