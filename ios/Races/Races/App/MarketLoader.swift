import Foundation
import RacesKit

/// The exchange's view of a day's card, joined to ours.
///
/// `snapshots` is keyed by **our** race id, so a caller never handles a Betfair
/// market id. Everything a screen needs to be honest about what it is showing is
/// here: how many races got a price, why the others did not, and whether the
/// fetch failed at all.
///
/// `nonisolated` and at file scope rather than nested in `MarketLoader`, for the
/// reason in CLAUDE.md: the app target defaults to MainActor isolation and
/// enables `InferIsolatedConformances`, so a nested type's `Equatable` would be
/// main-actor-isolated and could not satisfy a generic constraint — including
/// `XCTAssertEqual` from a nonisolated test.
nonisolated struct MarketLoad: Equatable, Sendable {
    /// By race id. A race absent here has no usable market, which is a normal
    /// state and never an error.
    let snapshots: [String: MarketSnapshot]
    /// Settlement coordinates by race id, for every race that **matched** —
    /// which is deliberately a wider set than `snapshots`.
    ///
    /// A market can match and still have nothing priced yet (an early-morning
    /// book with no money in it), and that race will still settle with a Betfair
    /// SP hours later. Gating the reference on live prices would lose the ROI
    /// figure for exactly the races that were hardest to price at the time.
    let references: [String: MarketReference]
    /// Why each unmatched race was refused, straight from the matcher. Kept
    /// because "no candidate market" and "runners didn't overlap" are different
    /// problems and only one of them is ours.
    let refusals: [String: MatchRefusal]
    /// How many win markets the exchange offered for the day, matched or not.
    let marketsSeen: Int
    let fetchedAt: Date
    /// Non-nil when the exchange could not be reached or refused us. Carried
    /// rather than thrown: the card still renders form-only, and the screen
    /// decides whether this is worth a line of text.
    let failure: APIError?

    static func unavailable(_ failure: APIError?, at moment: Date) -> MarketLoad {
        MarketLoad(
            snapshots: [:], references: [:], refusals: [:], marketsSeen: 0,
            fetchedAt: moment, failure: failure)
    }

    func reference(forRace raceID: String) -> MarketReference? {
        references[raceID]
    }

    func snapshot(forRace raceID: String) -> MarketSnapshot? {
        snapshots[raceID]
    }

    var pricedRaceCount: Int { snapshots.count }
}

/// One attempt at the market catalogue for a day, successful or not.
///
/// The failure is cached alongside the markets so a latched Betfair login — a
/// 2FA challenge, a certificate requirement — is not re-attempted on every pull
/// to refresh. `BetfairSession` already refuses to retry those without a
/// network call, but a screen that asks ten times a minute still looks wrong in
/// a log.
private nonisolated struct CatalogueAttempt: Sendable {
    let markets: [ExchangeMarket]
    let fetchedAt: Date
    let failure: APIError?
}

private nonisolated struct PriceAttempt: Sendable {
    let prices: ExchangeMarketPrices
    let fetchedAt: Date
}

/// Fetches exchange prices for a day's races and joins them to our runners.
///
/// Held by `AppEnvironment` rather than made per screen, unlike `RacecardLoader`:
/// a market fetch is a catalogue call plus a book call per forty markets, and
/// Tips and a race detail screen opened one after the other should cost one of
/// each, not two. That is also why the cache holds the *provider's* answers and
/// re-runs the match each time — matching is pure and free, the network is not.
///
/// It never throws. A missing, refused or unmatched market is an ordinary state
/// the rater is built for: it falls back to form only and `RaceAssessment`
/// reports `isFormOnly`, which the UI says out loud.
@MainActor
final class MarketLoader {

    /// Prices move; the catalogue barely does. `docs/providers.md` records both
    /// figures, and these are the same ones.
    static let priceFreshness: TimeInterval = 5 * 60
    static let catalogueFreshness: TimeInterval = 15 * 60

    private var provider: (any MarketDataProviding)?
    private var catalogues: [RaceDay: CatalogueAttempt] = [:]
    private var priceCache: [String: PriceAttempt] = [:]

    init(provider: (any MarketDataProviding)?) {
        self.provider = provider
    }

    var isConfigured: Bool { provider != nil }

    /// Point the loader at a new provider, discarding everything fetched with
    /// the old one.
    ///
    /// The provider is swapped in place rather than the whole loader being
    /// replaced, because screens capture this object when their view model is
    /// built and SwiftUI keeps that `@State` alive across a credential change.
    /// A replaced loader would leave Tips holding one with no Betfair provider
    /// until the app was relaunched — exactly the thing `AppEnvironment.refresh()`
    /// exists to avoid. The caches go because prices fetched under another app
    /// key are not ours to show.
    func use(provider: (any MarketDataProviding)?) {
        self.provider = provider
        catalogues.removeAll()
        priceCache.removeAll()
    }

    /// Prices for the given races, matched by `RaceMatcher`.
    ///
    /// Safe to call with a single race: the matcher scores candidates on runner
    /// overlap and refuses ties, so it does not need the rest of the card to
    /// tell two meetings at one course apart.
    func load(
        races: [Race],
        day: RaceDay,
        forceRefresh: Bool = false,
        now: Date = Date()
    ) async -> MarketLoad {
        guard provider != nil else {
            return .unavailable(.notConfigured(provider: "Betfair"), at: now)
        }
        guard !races.isEmpty else { return .unavailable(nil, at: now) }

        let catalogue = await fetchCatalogue(day: day, forceRefresh: forceRefresh, now: now)
        if let failure = catalogue.failure, catalogue.markets.isEmpty {
            return .unavailable(failure, at: catalogue.fetchedAt)
        }

        let report = RaceMatcher.match(races: races, markets: catalogue.markets)
        let matches = report.matchesByRaceID
        guard !matches.isEmpty else {
            return MarketLoad(
                snapshots: [:], references: [:], refusals: report.refusals,
                marketsSeen: catalogue.markets.count,
                fetchedAt: catalogue.fetchedAt, failure: nil)
        }

        // Built from the matches, before pricing, so a matched-but-unpriced race
        // still gets its settlement coordinates.
        let references = matches.mapValues { $0.reference() }

        // Only matched markets are priced. Asking for the whole catalogue would
        // cost a book call per forty markets to price races we cannot join.
        let books = await fetchBooks(
            forMarketIDs: matches.values.map(\.marketID),
            forceRefresh: forceRefresh,
            now: now)

        var snapshots: [String: MarketSnapshot] = [:]
        for (raceID, match) in matches {
            guard let attempt = books[match.marketID] else { continue }
            let snapshot = match.snapshot(
                from: attempt.prices,
                source: Self.source(for: day))
            // A book with nothing priced is not a market. The rater is already
            // safe from it — every implied probability comes out nil, coverage
            // is 0 and the assessment stays form-only — but counting the race
            // as priced would overstate the Tips coverage line, whose whole job
            // is to show when the model is not anchored.
            guard snapshot.prices.values.contains(where: { $0.hasAnyPrice }) else { continue }
            snapshots[raceID] = snapshot
        }

        return MarketLoad(
            snapshots: snapshots,
            references: references,
            refusals: report.refusals,
            marketsSeen: catalogue.markets.count,
            fetchedAt: catalogue.fetchedAt,
            failure: nil)
    }

    /// Tomorrow's markets have no liquidity worth anchoring to, so they are
    /// labelled forecast rather than live. The rater and the UI both key off
    /// this, and implying a live market the day before is the sort of thing that
    /// looks entirely normal and is simply untrue.
    private static func source(for day: RaceDay) -> MarketSnapshot.Source {
        switch day {
        case .today: return .liveExchange
        case .tomorrow: return .forecast
        }
    }

    // MARK: - Caching

    private func fetchCatalogue(
        day: RaceDay,
        forceRefresh: Bool,
        now: Date
    ) async -> CatalogueAttempt {
        if !forceRefresh,
           let cached = catalogues[day],
           now.timeIntervalSince(cached.fetchedAt) < Self.freshness(for: cached) {
            return cached
        }
        guard let provider else {
            return CatalogueAttempt(markets: [], fetchedAt: now, failure: .notConfigured(provider: "Betfair"))
        }

        let attempt: CatalogueAttempt
        do {
            let markets = try await provider.markets(day: day)
            attempt = CatalogueAttempt(markets: markets, fetchedAt: now, failure: nil)
        } catch let refusal as BetfairLoginFailure {
            // `asAPIError` rather than `from`, which would flatten this to
            // `.network(.unknown)` and lose Betfair's own reason. A 2FA
            // challenge reported as "couldn't reach the exchange" sends the user
            // looking for a network problem they do not have.
            attempt = CatalogueAttempt(
                markets: [], fetchedAt: now, failure: refusal.asAPIError)
        } catch {
            attempt = CatalogueAttempt(markets: [], fetchedAt: now, failure: .from(error))
        }
        catalogues[day] = attempt
        return attempt
    }

    /// A failed attempt is held for the shorter window. Retrying a refused login
    /// every fifteen minutes is fine; retrying a transient timeout only then
    /// would strand the screen on form-only for a quarter of an hour.
    private static func freshness(for attempt: CatalogueAttempt) -> TimeInterval {
        attempt.failure == nil ? catalogueFreshness : priceFreshness
    }

    private func fetchBooks(
        forMarketIDs marketIDs: [String],
        forceRefresh: Bool,
        now: Date
    ) async -> [String: PriceAttempt] {
        var fresh: [String: PriceAttempt] = [:]
        var wanted: [String] = []

        for marketID in Set(marketIDs) {
            if !forceRefresh,
               let cached = priceCache[marketID],
               now.timeIntervalSince(cached.fetchedAt) < Self.priceFreshness {
                fresh[marketID] = cached
            } else {
                wanted.append(marketID)
            }
        }

        guard !wanted.isEmpty, let provider else { return fresh }

        do {
            // The client batches to Betfair's forty-market cap and halves on
            // `TOO_MUCH_DATA`, so one call here is correct however long the list.
            for book in try await provider.prices(marketIDs: wanted) {
                let attempt = PriceAttempt(prices: book, fetchedAt: now)
                priceCache[book.marketID] = attempt
                fresh[book.marketID] = attempt
            }
        } catch {
            // Whatever we already had stays usable. A stale price is a worse
            // anchor than a fresh one and a far better one than none, and the
            // snapshot carries `capturedAt` so nothing pretends otherwise.
        }

        return fresh
    }
}
