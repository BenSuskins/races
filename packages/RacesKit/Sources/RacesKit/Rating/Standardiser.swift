import Foundation

/// Turns raw factor values into within-race z-scores.
///
/// Standardising **within the race** rather than globally is the important part.
/// An official rating of 82 is strong in a Class 6 and weak in a Group 2; the only
/// meaningful question is how a runner compares with the others it is actually
/// facing today.
public enum Standardiser {

    /// z-scores over the values that are present, clipped to `±clip`.
    ///
    /// Two deliberate behaviours:
    ///
    /// - A runner with **no value gets 0**, which is race-neutral. It is never
    ///   imputed to the mean of something else, and never treated as the minimum.
    ///   A horse with no official rating is unknown, not bad.
    /// - When every runner has the same value, or fewer than two have one at all,
    ///   **everyone gets 0**. A factor that cannot discriminate should contribute
    ///   nothing rather than amplifying floating-point noise into a selection.
    public static func zScores(_ values: [Double?], clip: Double = 2.5) -> [Double] {
        let present = values.compactMap { $0 }.filter(\.isFinite)
        guard present.count >= 2 else {
            return Array(repeating: 0, count: values.count)
        }

        let count = Double(present.count)
        let mean = present.reduce(0, +) / count
        let variance = present.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let standardDeviation = variance.squareRoot()

        guard standardDeviation > 1e-9 else {
            return Array(repeating: 0, count: values.count)
        }

        return values.map { value in
            guard let value, value.isFinite else { return 0 }
            return min(max((value - mean) / standardDeviation, -clip), clip)
        }
    }
}
