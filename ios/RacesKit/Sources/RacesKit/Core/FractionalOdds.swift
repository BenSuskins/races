import Foundation

/// Decimal odds shown the way a British bookmaker prints them.
///
/// Betfair trades on a decimal ladder with steps no bookmaker uses — 3.45, 7.8 —
/// so an exact conversion would print 29/20 and 34/5, which nobody reads. The
/// price is snapped to the nearest step on the traditional fractional ladder
/// instead, measured as a ratio so that 1/5 against 2/9 is weighed the same way
/// as 20/1 against 22/1. The display is therefore an approximation of the
/// exchange price, the same one a bookmaker makes when it chalks up a board.
public enum FractionalOdds {

    /// The traditional ladder, shortest first, as numerator and denominator.
    /// Written the way the board shows it: 4/6 rather than 2/3.
    static let ladder: [(numerator: Int, denominator: Int)] = [
        (1, 50), (1, 33), (1, 25), (1, 20), (1, 16), (1, 14), (1, 12), (1, 10),
        (1, 9), (1, 8), (2, 15), (1, 7), (1, 6), (2, 11), (1, 5), (2, 9),
        (1, 4), (2, 7), (3, 10), (1, 3), (4, 11), (2, 5), (4, 9), (1, 2),
        (8, 15), (4, 7), (8, 13), (4, 6), (8, 11), (4, 5), (5, 6), (10, 11),
        (1, 1), (11, 10), (6, 5), (5, 4), (11, 8), (6, 4), (13, 8), (7, 4),
        (15, 8), (2, 1), (9, 4), (5, 2), (11, 4), (3, 1), (10, 3), (7, 2),
        (4, 1), (9, 2), (5, 1), (11, 2), (6, 1), (13, 2), (7, 1), (15, 2),
        (8, 1), (17, 2), (9, 1), (10, 1), (11, 1), (12, 1), (14, 1), (16, 1),
        (18, 1), (20, 1), (22, 1), (25, 1), (28, 1), (33, 1), (40, 1), (50, 1),
        (66, 1), (80, 1), (100, 1), (125, 1), (150, 1), (200, 1), (250, 1),
        (300, 1), (500, 1), (1000, 1),
    ]

    /// "5/2", "Evens", "4/6" — or `nil` for a price that is not a price: at or
    /// below 1.0, or infinite (the fair odds of a zero probability).
    public static func display(decimal: Double) -> String? {
        guard decimal.isFinite, decimal > 1 else { return nil }
        let target = log(decimal - 1)
        var best = ladder[0]
        var bestDistance = Double.infinity
        for step in ladder {
            let distance = abs(log(Double(step.numerator) / Double(step.denominator)) - target)
            if distance < bestDistance {
                best = step
                bestDistance = distance
            }
        }
        if best.numerator == best.denominator { return "Evens" }
        return "\(best.numerator)/\(best.denominator)"
    }
}
