import Foundation
import RacesKit

/// One racecard, and where it came from.
///
/// `servedStaleAfterFailure` is the point of this type. A cold launch on a train
/// should show yesterday's saved card rather than a spinner and an error, but it
/// must not pass it off as current — so the screen gets the facts and decides what
/// to say.
nonisolated struct RacecardLoad: Sendable {
    let races: [Race]
    let fetchedAt: Date
    let servedStaleAfterFailure: Bool

    var isFresh: Bool { !servedStaleAfterFailure }
}

/// Fetches a day's card, through the disk cache.
///
/// Shared by Today and Tips so the two cannot disagree about what is running, and
/// so opening both does not cost two requests against a 1 req/s free tier. The
/// cache is on disk rather than in memory because a cold launch is the case that
/// actually matters — in-memory freshness only ever helped within one session.
@MainActor
final class RacecardLoader {

    private let provider: (any RacingDataProviding)?
    private let store: RacesStore

    init(provider: (any RacingDataProviding)?, store: RacesStore) {
        self.provider = provider
        self.store = store
    }

    func load(
        day: RaceDay,
        forceRefresh: Bool = false,
        now: Date = Date()
    ) async throws -> RacecardLoad {
        let dayString = RaceDates.dayString(for: day, now: now)
        let cached = await store.cachedRacecards(day: dayString)

        if !forceRefresh,
           let cached,
           now.timeIntervalSince(cached.fetchedAt) < StoreDocument.racecardFreshness {
            return RacecardLoad(
                races: cached.races,
                fetchedAt: cached.fetchedAt,
                servedStaleAfterFailure: false)
        }

        guard let provider else {
            // Cached content is still worth showing with no credentials — the user
            // may simply have cleared them, and the card they last saw is real.
            if let cached {
                return RacecardLoad(
                    races: cached.races,
                    fetchedAt: cached.fetchedAt,
                    servedStaleAfterFailure: true)
            }
            throw APIError.notConfigured(provider: "The Racing API")
        }

        do {
            let races = try await provider.racecards(
                day: day, regionCodes: BrowseRegions.codes)
            await store.saveRacecards(races, day: dayString, fetchedAt: now)
            return RacecardLoad(races: races, fetchedAt: now, servedStaleAfterFailure: false)
        } catch {
            // A stale card beats an error screen, but only if we say it is stale.
            if let cached {
                return RacecardLoad(
                    races: cached.races,
                    fetchedAt: cached.fetchedAt,
                    servedStaleAfterFailure: true)
            }
            throw APIError.from(error)
        }
    }
}
