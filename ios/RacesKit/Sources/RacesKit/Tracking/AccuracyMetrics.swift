import Foundation

/// Return on a flat one-point stake.
public struct ROI: Codable, Hashable, Sendable {
    public let bets: Int
    public let returned: Double

    public init(bets: Int, returned: Double) {
        self.bets = bets
        self.returned = returned
    }

    public var staked: Double { Double(bets) }
    public var profit: Double { returned - staked }
    /// Profit as a share of turnover. Nil with no bets, rather than a
    /// meaningless zero that would read as "broke even".
    public var percentage: Double? {
        bets > 0 ? profit / staked : nil
    }
}

/// Performance over some subset of tips.
public struct SubsetPerformance: Codable, Hashable, Sendable {
    public let settled: Int
    public let wins: Int
    public let roi: ROI?

    public init(settled: Int, wins: Int, roi: ROI?) {
        self.settled = settled
        self.wins = wins
        self.roi = roi
    }

    public var strikeRate: Double? {
        settled > 0 ? Double(wins) / Double(settled) : nil
    }

    public static let empty = SubsetPerformance(settled: 0, wins: 0, roi: nil)
}

/// What the tips actually did.
///
/// Three things here exist specifically to stop the app flattering itself, and
/// none of them should be removed without a good reason:
///
/// 1. **The favourite baseline.** A 32% strike rate sounds excellent until you
///    learn the favourite won 34% of the same races. It is the only honest answer
///    to "is this algorithm any good?"
/// 2. **The agree/disagree split.** When the tip *was* the favourite, the model
///    contributed nothing. All of its actual information is in the subset where
///    it disagreed, and that is where it earns or loses its keep.
/// 3. **Separate denominators.** Strike rate and ROI count different races —
///    ROI needs a starting price and many races will not have one. Blending them
///    is how tipping records quietly overstate themselves.
public struct AccuracyReport: Codable, Hashable, Sendable {

    /// Below this, level-stakes ROI is noise, and showing it would invite exactly
    /// the wrong conclusion.
    public static let minimumSampleForROI = 50

    public let total: Int
    public let settled: Int
    public let wins: Int
    public let voided: Int
    public let unresolved: Int
    public let expired: Int
    public let pending: Int

    /// Share of finished races we actually know the outcome of. Displayed, so a
    /// record built from a biased subsample cannot pass as a complete one.
    public let coverage: Double

    public let expectedWins: Double
    public let brierScore: Double?

    public let roi: ROI?
    /// Settled tips with no starting price, and so outside the ROI figure.
    public let settledWithoutPrice: Int

    public let favouriteBaseline: SubsetPerformance
    public let whenAgreeingWithFavourite: SubsetPerformance
    public let whenDisagreeing: SubsetPerformance

    public var strikeRate: Double? {
        settled > 0 ? Double(wins) / Double(settled) : nil
    }

    /// What the model said should happen, against what did. A model saying 25%
    /// and hitting 25% is *working*, even if the overround makes it unprofitable.
    public var expectedStrikeRate: Double? {
        settled > 0 ? expectedWins / Double(settled) : nil
    }

    public var calibrationError: Double? {
        guard let strikeRate, let expectedStrikeRate else { return nil }
        return strikeRate - expectedStrikeRate
    }

    public var isSufficientSampleForROI: Bool {
        settled >= Self.minimumSampleForROI
    }

    /// Whether the model beat simply backing the favourite, on strike rate.
    /// Nil until both have something to say.
    public var beatsFavouriteOnStrikeRate: Bool? {
        guard let mine = strikeRate, let theirs = favouriteBaseline.strikeRate else { return nil }
        return mine > theirs
    }
}

public enum AccuracyCalculator {

    /// Betfair's base commission. The user's real rate varies with their discount
    /// and points allowance, so it is a setting — and both gross and net matter,
    /// which is why it is a parameter rather than a constant.
    public static let defaultCommission = 0.05

    public static func report(
        for tips: [TipRecord],
        commission: Double = defaultCommission
    ) -> AccuracyReport {
        var settled = 0
        var wins = 0
        var voided = 0
        var unresolved = 0
        var expired = 0
        var pending = 0

        var expectedWins = 0.0
        var brierTotal = 0.0

        var roiBets = 0
        var roiReturned = 0.0
        var settledWithoutPrice = 0

        var favouriteSettled = 0
        var favouriteWins = 0
        var favouriteBets = 0
        var favouriteReturned = 0.0

        var agreed = (settled: 0, wins: 0, bets: 0, returned: 0.0)
        var disagreed = (settled: 0, wins: 0, bets: 0, returned: 0.0)

        for tip in tips {
            switch tip.outcome {
            case .none:
                pending += 1
                continue
            case .some(.unresolved):
                unresolved += 1
                continue
            case .some(.expired):
                expired += 1
                continue
            case .some(let outcome) where outcome.isVoid:
                voided += 1
                continue
            case .some(let outcome):
                settled += 1
                let won = outcome.isWin
                if won { wins += 1 }

                expectedWins += tip.predictedProbability
                let actual = won ? 1.0 : 0.0
                brierTotal += pow(tip.predictedProbability - actual, 2)

                // ROI needs a price. Races without one are excluded from the
                // figure and counted separately rather than silently folded in.
                if let price = outcome.betfairSP, price > 1 {
                    roiBets += 1
                    let payout = returnFor(won: won, price: price, commission: commission)
                    roiReturned += payout

                    if tip.agreedWithFavourite == true {
                        agreed.bets += 1
                        agreed.returned += payout
                    } else if tip.agreedWithFavourite == false {
                        disagreed.bets += 1
                        disagreed.returned += payout
                    }
                } else {
                    settledWithoutPrice += 1
                }

                if tip.agreedWithFavourite == true {
                    agreed.settled += 1
                    if won { agreed.wins += 1 }
                } else if tip.agreedWithFavourite == false {
                    disagreed.settled += 1
                    if won { disagreed.wins += 1 }
                }

                // The baseline: what backing the favourite would have done over
                // exactly these races.
                if let favourite = tip.favouriteOutcome {
                    favouriteSettled += 1
                    if favourite.won { favouriteWins += 1 }
                    if let price = favourite.betfairSP, price > 1 {
                        favouriteBets += 1
                        favouriteReturned += returnFor(
                            won: favourite.won, price: price, commission: commission
                        )
                    }
                }
            }
        }

        let finished = settled + voided + unresolved + expired
        let known = settled + voided

        return AccuracyReport(
            total: tips.count,
            settled: settled,
            wins: wins,
            voided: voided,
            unresolved: unresolved,
            expired: expired,
            pending: pending,
            coverage: finished > 0 ? Double(known) / Double(finished) : 1,
            expectedWins: expectedWins,
            brierScore: settled > 0 ? brierTotal / Double(settled) : nil,
            roi: roiBets > 0 ? ROI(bets: roiBets, returned: roiReturned) : nil,
            settledWithoutPrice: settledWithoutPrice,
            favouriteBaseline: SubsetPerformance(
                settled: favouriteSettled,
                wins: favouriteWins,
                roi: favouriteBets > 0 ? ROI(bets: favouriteBets, returned: favouriteReturned) : nil
            ),
            whenAgreeingWithFavourite: SubsetPerformance(
                settled: agreed.settled,
                wins: agreed.wins,
                roi: agreed.bets > 0 ? ROI(bets: agreed.bets, returned: agreed.returned) : nil
            ),
            whenDisagreeing: SubsetPerformance(
                settled: disagreed.settled,
                wins: disagreed.wins,
                roi: disagreed.bets > 0 ? ROI(bets: disagreed.bets, returned: disagreed.returned) : nil
            )
        )
    }

    /// Return on a one-point stake. A winner pays the price less the stake, net of
    /// commission on the profit; a loser returns nothing.
    static func returnFor(won: Bool, price: Double, commission: Double) -> Double {
        guard won else { return 0 }
        let profit = (price - 1) * (1 - max(0, min(commission, 1)))
        return 1 + profit
    }
}
