import Foundation
import RacesKit

/// Document names and cache policy.
///
/// `nonisolated`, and at file scope rather than nested in the actor, because a
/// nested type or a static inside the actor can pick up the app target's
/// MainActor default — and every one of the actor's own methods reads these from
/// off the main actor.
nonisolated enum StoreDocument {
    static let tips = "tips.json"
    static let archive = "archive.json"
    static func racecards(day: String) -> String { "racecards-\(day).json" }

    /// Cards go stale through the afternoon as non-runners come out, so this is
    /// short. It is the same window the browse screens used before there was a
    /// disk cache, now applied to the cache rather than to memory.
    static let racecardFreshness: TimeInterval = 15 * 60
}

/// What one pass of results actually changed. Returned so the UI can say
/// something true rather than "refreshed".
nonisolated struct ResultsIngestion: Hashable, Sendable {
    var newRacesArchived: Int = 0
    var tipsSettled: Int = 0

    var changedAnything: Bool { newRacesArchived > 0 || tipsSettled > 0 }
}

nonisolated struct CachedRacecards: Codable, Hashable, Sendable {
    let fetchedAt: Date
    let races: [Race]
}

/// Everything the app keeps between launches, in one isolation domain.
///
/// An actor rather than a `@MainActor` type because persistence is `async` and
/// the background refresh task touches it off the main thread. Keeping the ledger
/// and the archive behind one actor also means a tip write and a results ingest
/// cannot interleave, which matters: both mutate state the accuracy report is
/// computed from.
///
/// Nothing here reaches the network. The store is given results and races; it
/// decides what to keep. That keeps it testable against `InMemoryDocumentStore`
/// with no provider at all.
actor RacesStore {

    private let documents: any DocumentStoring
    private let rater: RaceRater

    private var ledger = TipLedger()
    private var archive = ResultsArchive()
    private var hasLoaded = false

    init(documents: any DocumentStoring, rater: RaceRater = RaceRater()) {
        self.documents = documents
        self.rater = rater
    }

    // MARK: - Loading

    /// Read what is on disk. Safe to call repeatedly; only the first call works.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        ledger = await load(TipLedger.self, from: StoreDocument.tips) ?? TipLedger()
        archive = await load(ResultsArchive.self, from: StoreDocument.archive) ?? ResultsArchive()
    }

    /// A read failure reads as "nothing stored". The store itself already treats
    /// an unreadable or future-schema file that way, and there is nothing a user
    /// could do about it — losing history is bad, refusing to open is worse.
    private func load<T: Codable & Sendable>(_ type: T.Type, from name: String) async -> T? {
        do { return try await documents.load(type, from: name) } catch { return nil }
    }

    // MARK: - Reading

    var tips: [TipRecord] {
        ledger.tips
    }

    var archivedRaceCount: Int {
        archive.raceCount
    }

    var hasArchive: Bool {
        archive.raceCount > 0
    }

    /// Betfair market ids for tips still waiting on a starting price.
    ///
    /// Read by `AppEnvironment.refreshResults()` so the exchange is only asked
    /// about races that actually need it — a settled BSP never changes, so a tip
    /// that already has one is not re-requested.
    func marketIDsAwaitingStartingPrice(now: Date = Date()) -> [String] {
        ledger.marketIDsAwaitingStartingPrice(now: now)
    }

    func report(commission: Double = AccuracyCalculator.defaultCommission) -> AccuracyReport {
        AccuracyCalculator.report(for: ledger.tips, commission: commission)
    }

    func tip(forRace raceID: String) -> TipRecord? {
        ledger.tip(forRace: raceID)
    }

    // MARK: - Rating

    /// Rate a race using whatever the archive currently knows, anchored to the
    /// market if one was matched.
    ///
    /// `market` is optional and stays optional. No Betfair credentials, a race
    /// the matcher refused, or a book with no usable prices all arrive here the
    /// same way — as `nil` — and the rater is built for it: it swaps to
    /// `formInfluenceNoMarket` and flags the result `isFormOnly`, so the UI says
    /// so rather than implying a market-anchored number.
    ///
    /// The store deliberately does no fetching and no matching. It is handed the
    /// snapshot, which is what keeps it testable with no provider at all.
    func assess(
        _ race: Race,
        market: MarketSnapshot? = nil,
        now: Date = Date()
    ) -> RaceAssessment {
        rater.rate(race, market: market, strikeRates: archive, now: now)
    }

    /// Assess a day's races and record a tip for each, persisting once.
    ///
    /// `markets` is keyed by race id, so a race with no entry is rated on form
    /// alone. A partially priced card is normal — some races match, some do not —
    /// and each tip records which it was.
    ///
    /// One save at the end rather than one per race: a 40-race card would
    /// otherwise rewrite the ledger forty times, and the whole point of the
    /// sealing rule is that the *last* write before the off is the one that counts.
    @discardableResult
    func assessAndRecord(
        _ races: [Race],
        markets: [String: MarketSnapshot] = [:],
        references: [String: MarketReference] = [:],
        now: Date = Date()
    ) async -> [String: RaceAssessment] {
        var assessments: [String: RaceAssessment] = [:]
        var stored = false

        for race in races {
            let assessment = assess(race, market: markets[race.id], now: now)
            assessments[race.id] = assessment
            // The reference is frozen with the tip, not looked up at settlement:
            // by the time a race settles, the catalogue that produced the match
            // may be gone, and re-matching a run race is guesswork.
            if ledger.record(
                assessment,
                race: race,
                marketReference: references[race.id],
                now: now
            ).didStore {
                stored = true
            }
        }

        if stored { await persistLedger() }
        return assessments
    }

    // MARK: - Results

    /// Fold today's results into the archive and settle any tip they answer.
    ///
    /// Idempotent by way of `ResultsArchive.ingestedRaceIDs`, which matters because
    /// this runs repeatedly through an afternoon — counting a race twice would
    /// inflate every strike rate derived from it.
    @discardableResult
    func ingest(
        results: [RaceResult],
        startingPrices: [String: [Int64: Double]] = [:],
        now: Date = Date()
    ) async -> ResultsIngestion {
        var ingestion = ResultsIngestion()

        ingestion.newRacesArchived = archive.ingest(results)

        let resultsByRaceID = Dictionary(
            results.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        // `awaitingReconciliation` only returns tips with no final outcome, so
        // `replace` cannot un-settle a settled race here.
        for tip in ledger.awaitingReconciliation(now: now) {
            // Betfair's reply is keyed by its own selection ids; the reference
            // frozen with the tip is what turns it back into our horse ids, and
            // drops anything it cannot place rather than guessing.
            let betfairSPs = tip.marketReference?
                .startingPrices(from: startingPrices) ?? [:]

            let settled = ResultReconciler.settle(
                tip: tip,
                result: resultsByRaceID[tip.raceID],
                betfairStartingPrices: betfairSPs,
                now: now)
            guard settled != tip else { continue }
            ledger.replace(settled)
            if settled.outcome?.isSettled == true || settled.outcome?.isVoid == true {
                ingestion.tipsSettled += 1
            }
        }

        if ingestion.newRacesArchived > 0 { await persistArchive() }
        if ingestion.tipsSettled > 0 || !ledger.awaitingReconciliation(now: now).isEmpty {
            // Attempt counts advance even when nothing settles, and losing those
            // would keep a dead tip being retried forever instead of expiring.
            await persistLedger()
        }

        return ingestion
    }

    // MARK: - Racecard cache

    func cachedRacecards(day: String) async -> CachedRacecards? {
        await load(CachedRacecards.self, from: StoreDocument.racecards(day: day))
    }

    func saveRacecards(_ races: [Race], day: String, fetchedAt: Date = Date()) async {
        let cached = CachedRacecards(fetchedAt: fetchedAt, races: races)
        try? await documents.save(cached, to: StoreDocument.racecards(day: day))
    }

    // MARK: - Persistence

    private func persistLedger() async {
        try? await documents.save(ledger, to: StoreDocument.tips)
    }

    private func persistArchive() async {
        try? await documents.save(archive, to: StoreDocument.archive)
    }

    /// For Settings' "clear history". Deliberately separate from clearing
    /// credentials: losing the accuracy record is not the same as signing out,
    /// and conflating them would let one destroy the other by accident.
    func clearHistory() async {
        ledger = TipLedger()
        archive = ResultsArchive()
        try? await documents.delete(StoreDocument.tips)
        try? await documents.delete(StoreDocument.archive)
    }
}
