import Foundation

/// Turns a settled race into a tip outcome.
///
/// Pure: it takes a tip and a result and returns an updated tip. No network, no
/// disk, no clock beyond the `now` passed in — so every awkward case has a test
/// rather than a hope.
public enum ResultReconciler {

    /// How long to keep looking for a result before giving up.
    ///
    /// The free results endpoint covers **today only**. If the app is not opened
    /// on the evening of a race day, those results are gone for good. Rather than
    /// leaving such tips pending forever, they expire — and the report counts
    /// them, so the numbers can never quietly become a biased subsample.
    public static let expiryDays = 7
    public static let maximumAttempts = 10

    public static func settle(
        tip: TipRecord,
        result: RaceResult?,
        betfairStartingPrices: [String: Double] = [:],
        meetingAbandoned: Bool = false,
        now: Date = Date()
    ) -> TipRecord {
        var settled = tip

        if meetingAbandoned {
            settled.outcome = .abandoned
            return settled
        }

        guard let result else {
            settled.outcome = giveUpOrKeepTrying(tip: tip, now: now)
            return settled
        }

        // A horse absent from a settled result was withdrawn — void, not beaten.
        // `didRun` returns nil for a suspiciously small field, which stops a
        // truncated payload settling every runner as a non-runner and wiping a
        // day of tips in one pass.
        switch result.didRun(horseID: tip.selectionHorseID) {
        case .some(false):
            settled.outcome = .nonRunner
        case .none:
            settled.outcome = giveUpOrKeepTrying(tip: tip, now: now)
        case .some(true):
            let finisher = result.finisher(horseID: tip.selectionHorseID)
            let startingPrice = betfairStartingPrices[tip.selectionHorseID]
                ?? finisher?.startingPriceDecimal

            if finisher?.position.isWinner == true {
                settled.outcome = .won(betfairSP: startingPrice)
            } else {
                settled.outcome = .lost(
                    position: finisher?.position.numericPosition,
                    betfairSP: startingPrice
                )
            }
        }

        settled.favouriteOutcome = favouriteOutcome(
            tip: tip,
            result: result,
            betfairStartingPrices: betfairStartingPrices
        ) ?? settled.favouriteOutcome

        return settled
    }

    /// Whether the favourite obliged, recorded now because the free results
    /// endpoint will not have this race tomorrow.
    static func favouriteOutcome(
        tip: TipRecord,
        result: RaceResult,
        betfairStartingPrices: [String: Double]
    ) -> FavouriteOutcome? {
        guard let favouriteID = tip.marketFavouriteHorseID,
              result.didRun(horseID: favouriteID) == true else { return nil }

        let finisher = result.finisher(horseID: favouriteID)
        return FavouriteOutcome(
            horseID: favouriteID,
            won: finisher?.position.isWinner == true,
            betfairSP: betfairStartingPrices[favouriteID] ?? finisher?.startingPriceDecimal
        )
    }

    private static func giveUpOrKeepTrying(tip: TipRecord, now: Date) -> TipOutcome {
        let attempts: Int
        if case .unresolved(_, let previous) = tip.outcome {
            attempts = previous + 1
        } else {
            attempts = 1
        }

        let tooOld = tip.offAt.map {
            now > $0.addingTimeInterval(Double(expiryDays) * 24 * 60 * 60)
        } ?? false

        if tooOld || attempts >= maximumAttempts {
            return .expired(at: now)
        }
        return .unresolved(lastCheckedAt: now, attempts: attempts)
    }
}
