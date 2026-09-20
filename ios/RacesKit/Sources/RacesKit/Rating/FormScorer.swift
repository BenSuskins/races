import Foundation

/// Turns a parsed form line into a single number in `0...1`.
///
/// Recent runs count for more, via geometric decay, and runs the other side of a
/// break count for less again. Everything is configurable because **none of these
/// numbers are fitted** — they are reasonable hand-chosen values, and the whole
/// point of putting them in `RatingWeights` is so the back-test can replace them
/// with something earned.
///
/// The structural weakness to keep in mind: a form string says a horse finished
/// first, not *in what*. A Class 7 seller and a Group 1 both read `1`. This is why
/// the form weight stays modest and the market anchor does the heavy lifting.
public struct FormScorer: Hashable, Sendable {

    public let points: [String: Double]
    /// Geometric decay applied backwards from the most recent run.
    public let decay: Double
    /// Multiplier applied to everything older than a season break.
    public let seasonBreakPenalty: Double
    /// Multiplier applied to everything older than a long break.
    public let longBreakPenalty: Double
    /// How far back to look. Beyond about six runs the information is stale and
    /// the decay has made it nearly weightless anyway.
    public let maxRuns: Int

    public init(
        points: [String: Double] = FormScorer.defaultPoints,
        decay: Double = 0.75,
        seasonBreakPenalty: Double = 0.80,
        longBreakPenalty: Double = 0.50,
        maxRuns: Int = 6
    ) {
        self.points = points
        self.decay = decay
        self.seasonBreakPenalty = seasonBreakPenalty
        self.longBreakPenalty = longBreakPenalty
        self.maxRuns = maxRuns
    }

    /// Hand-chosen, not fitted. Recorded in `docs/algorithm.md` as such.
    public static let defaultPoints: [String: Double] = [
        "1": 1.00, "2": 0.72, "3": 0.55, "4": 0.42, "5": 0.32,
        "6": 0.25, "7": 0.20, "8": 0.16, "9": 0.13,
        "tenOrWorse": 0.05,
        "nonCompletion": 0.00,
    ]

    /// The scoring key for an outcome, so points stay tunable data rather than
    /// numbers buried in a switch.
    static func tag(for outcome: FormOutcome) -> String? {
        switch outcome {
        case .finished(let position):
            return position >= 10 ? "tenOrWorse" : String(position)
        case .pulledUp, .unseatedRider, .fell, .refused, .broughtDown, .slippedUp, .disqualified:
            return "nonCompletion"
        // A voided race tells us nothing about the horse, so it is skipped
        // entirely rather than scored as a failure.
        case .voided, .seasonBreak, .longBreak, .unrecognised:
            return nil
        }
    }

    /// Weighted average of recent form in `0...1`, or nil for a horse with no runs.
    ///
    /// A weighted *average* rather than a sum, so a horse with two runs is not
    /// punished against one with six purely for having run less often. Whether a
    /// short record should be discounted is a separate question, and one the
    /// back-test should answer rather than this function assuming.
    public func score(_ line: FormLine) -> Double? {
        var total = 0.0
        var totalWeight = 0.0
        var index = 0
        var breakMultiplier = 1.0

        for outcome in line.outcomes.reversed() {
            switch outcome {
            case .seasonBreak:
                breakMultiplier *= seasonBreakPenalty
                continue
            case .longBreak:
                breakMultiplier *= longBreakPenalty
                continue
            default:
                break
            }

            guard let tag = Self.tag(for: outcome) else { continue }
            guard index < maxRuns else { break }

            let weight = pow(decay, Double(index)) * breakMultiplier
            total += weight * (points[tag] ?? 0)
            totalWeight += weight
            index += 1
        }

        guard totalWeight > 0 else { return nil }
        return total / totalWeight
    }
}
