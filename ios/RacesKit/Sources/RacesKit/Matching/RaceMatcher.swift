import Foundation

/// One race joined to one market.
public struct RaceMarketMatch: Hashable, Sendable {
    public let raceID: String
    public let marketID: String
    public let minutesApart: Double
    /// Share of the field identified **by name alone**.
    ///
    /// This is the evidence the pairing rests on, kept separate from
    /// `runnerOverlap` because the two answer different questions. Names are what
    /// establish that this market is this race; saddle cloths then fill in the
    /// runners whose names one side spells oddly, and so cover more of the field
    /// than the names did.
    public let nameEvidence: Double
    public let runners: RunnerMatchResult

    public init(
        raceID: String,
        marketID: String,
        minutesApart: Double,
        nameEvidence: Double,
        runners: RunnerMatchResult
    ) {
        self.raceID = raceID
        self.marketID = marketID
        self.minutesApart = minutesApart
        self.nameEvidence = nameEvidence
        self.runners = runners
    }

    /// Share of the field carrying a selection, and therefore a price.
    public var runnerOverlap: Double { runners.overlap }

    /// True when any pairing needed the fuzzy name pass. Worth surfacing: it is
    /// the pass most likely to be wrong.
    public var usedSimilarNames: Bool {
        runners.pairings.contains { $0.basis == .similarName }
    }
}

/// Why a race ended up with no market.
///
/// Every one of these is an ordinary outcome rather than an error — the app has
/// to work with no market at all — but they are worth telling apart, because
/// `noOverlap` appearing often means the matcher is wrong while `noCandidate`
/// appearing often just means Betfair is not covering those meetings.
public enum MatchRefusal: Hashable, Sendable {
    /// The race has no usable off time, so nothing can be compared.
    case noOffTime
    /// No market at that course within the time window.
    case noCandidate
    /// More than one market fits equally well and nothing separates them.
    case ambiguous(marketIDs: [String])
    /// A market fit on course and time, but the fields do not overlap enough to
    /// believe it is the same race.
    case noOverlap(marketID: String, overlap: Double)
    /// The race has no declared runners to compare.
    case noRunners

    public var displayName: String {
        switch self {
        case .noOffTime: return "No off time"
        case .noCandidate: return "No market found"
        case .ambiguous: return "More than one market fits"
        case .noOverlap: return "Runners don't match"
        case .noRunners: return "No declared runners"
        }
    }
}

/// What one pass of matching produced.
public struct MatchReport: Hashable, Sendable {
    public let matches: [RaceMarketMatch]
    public let refusals: [String: MatchRefusal]
    /// Markets nothing claimed. Normally Irish or overseas cards, or non-win
    /// markets that should have been filtered out upstream.
    public let unclaimedMarketIDs: [String]

    public init(
        matches: [RaceMarketMatch],
        refusals: [String: MatchRefusal],
        unclaimedMarketIDs: [String]
    ) {
        self.matches = matches
        self.refusals = refusals
        self.unclaimedMarketIDs = unclaimedMarketIDs
    }

    public var matchesByRaceID: [String: RaceMarketMatch] {
        Dictionary(matches.map { ($0.raceID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Share of races offered that came away with a market. The number the debug
    /// screen shows, and the one a regression in matching would move.
    public var matchRate: Double {
        let total = matches.count + refusals.count
        guard total > 0 else { return 0 }
        return Double(matches.count) / Double(total)
    }
}

/// Joins our racecards to an exchange's markets.
///
/// Three things have to agree, and the third is what makes the first two safe:
///
/// 1. **Course**, after normalisation — `Catterick Bridge` is `Catterick`.
/// 2. **Scheduled off**, within the tolerance window.
/// 3. **The horses themselves** — at least `minimumRunnerOverlap` of our
///    declared field present in the market.
///
/// Course and time alone are not enough. Newmarket runs two meetings on the same
/// day at the same normalised course name; a re-timed card can put two races
/// within minutes of each other; an abandoned meeting's markets can linger. The
/// overlap check is what distinguishes "the same race" from "a race that looks
/// like it", and the matcher would be unsafe without it.
///
/// **Which is why step 3 counts names only.** Every race numbers its runners from
/// one, so saddle cloths agree between any two races of the same size and prove
/// nothing about whether a market belongs to a race. Scoring candidates with the
/// cloth pass enabled would hand full confidence to whichever market shared the
/// course and time — the exact mismatch this design exists to prevent. So
/// matching runs in two phases: candidates are scored on names, and only the
/// winner is re-matched with cloth numbers allowed, to pick up the runners whose
/// names one side spells differently.
///
/// **It refuses rather than guesses.** A wrong match is far worse than no match:
/// with no market the rater falls back to form only and says so in the UI, while
/// a wrong market silently anchors every runner's probability to another race's
/// prices. So ties are refused, thin overlaps are refused, and each refusal
/// carries its reason.
public enum RaceMatcher {

    public static func match(
        races: [Race],
        markets: [ExchangeMarket],
        tolerances: MatchingTolerances = .default
    ) -> MatchReport {
        var marketsByCourse: [String: [ExchangeMarket]] = [:]
        for market in markets {
            marketsByCourse[CourseNameNormaliser.key(market.venue), default: []].append(market)
        }

        var matches: [RaceMarketMatch] = []
        var refusals: [String: MatchRefusal] = [:]
        var claimedMarketIDs: Set<String> = []

        // Longest fields first. A ten-runner race and a two-runner match-bet
        // market can both sit at the same course and time; resolving the race we
        // can be most confident about first means it takes its market with it.
        let ordered = races.sorted { $0.declaredRunners.count > $1.declaredRunners.count }

        for race in ordered {
            let runners = race.declaredRunners
            guard !runners.isEmpty else {
                refusals[race.id] = .noRunners
                continue
            }
            guard let offAt = race.offDateTime else {
                refusals[race.id] = .noOffTime
                continue
            }

            let courseKey = CourseNameNormaliser.key(race.courseName)
            let window = tolerances.startTimeWindowMinutes * 60

            let candidates = (marketsByCourse[courseKey] ?? []).filter { market in
                !claimedMarketIDs.contains(market.id)
                    && abs(market.startTime.timeIntervalSince(offAt)) <= window
            }
            guard !candidates.isEmpty else {
                refusals[race.id] = .noCandidate
                continue
            }

            // Score every candidate on the field rather than taking the closest
            // in time. Time is the weaker signal of the two: two meetings at one
            // course are separated by which horses are in them, not by minutes.
            var scored: [(market: ExchangeMarket, result: RunnerMatchResult, apart: Double)] = []
            for market in candidates {
                let result = RunnerMatcher.match(
                    runners: runners,
                    selections: market.activeRunners,
                    tolerances: tolerances,
                    allowClothNumbers: false)
                let apart = abs(market.startTime.timeIntervalSince(offAt)) / 60
                scored.append((market, result, apart))
            }

            let viable = scored.filter { $0.result.overlap >= tolerances.minimumRunnerOverlap }

            guard !viable.isEmpty else {
                // Report the nearest miss, which is what a human debugging this
                // wants to see.
                let best = scored.max(by: { $0.result.overlap < $1.result.overlap })
                if let best {
                    refusals[race.id] = .noOverlap(
                        marketID: best.market.id, overlap: best.result.overlap)
                } else {
                    refusals[race.id] = .noCandidate
                }
                continue
            }

            // Overlap decides; time breaks a tie on overlap.
            let ranked = viable.sorted { lhs, rhs in
                if lhs.result.overlap != rhs.result.overlap {
                    return lhs.result.overlap > rhs.result.overlap
                }
                return lhs.apart < rhs.apart
            }

            guard let winner = ranked.first else {
                refusals[race.id] = .noCandidate
                continue
            }

            // Nothing separates the top two. Refusing costs this race its prices;
            // picking wrong costs it a wrong answer that looks right.
            if ranked.count > 1 {
                let runnerUp = ranked[1]
                if runnerUp.result.overlap == winner.result.overlap,
                   runnerUp.apart == winner.apart {
                    refusals[race.id] = .ambiguous(
                        marketIDs: [winner.market.id, runnerUp.market.id].sorted())
                    continue
                }
            }

            // Now that the market is settled, match again with cloth numbers
            // allowed. They cannot mislead about *which* race this is any more,
            // and they resolve the runners whose names the two feeds spell
            // differently — which is the job CLAUDE.md gives them.
            let finalRunners = RunnerMatcher.match(
                runners: runners,
                selections: winner.market.activeRunners,
                tolerances: tolerances,
                allowClothNumbers: true)

            claimedMarketIDs.insert(winner.market.id)
            matches.append(
                RaceMarketMatch(
                    raceID: race.id,
                    marketID: winner.market.id,
                    minutesApart: winner.apart,
                    nameEvidence: winner.result.overlap,
                    runners: finalRunners))
        }

        let unclaimed = markets.map(\.id).filter { !claimedMarketIDs.contains($0) }

        return MatchReport(
            matches: matches,
            refusals: refusals,
            unclaimedMarketIDs: unclaimed)
    }
}
