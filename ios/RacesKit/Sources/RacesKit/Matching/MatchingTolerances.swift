import Foundation

/// Every threshold the matcher uses, in one place.
///
/// Same reasoning as `RatingWeights`: numbers that decide behaviour belong
/// somewhere a test can sweep them and a reader can find them, not scattered
/// through the code that applies them.
public struct MatchingTolerances: Codable, Hashable, Sendable {

    /// How far apart two scheduled off times may be and still be the same race.
    ///
    /// Six minutes, not two. The providers disagree by more than you would
    /// expect: the Racing API publishes the advertised off while Betfair's
    /// `marketStartTime` tracks the card as it is re-timed through the day, and a
    /// two-minute window loses real matches after a delay. Six is still well
    /// inside the gap between consecutive races at one course, which is what the
    /// window has to avoid crossing.
    public var startTimeWindowMinutes: Double

    /// The share of our declared runners that must be present in the market
    /// before the pairing is believed.
    ///
    /// This is the check that makes the rest safe. Course and time can both agree
    /// and still be the wrong race — two meetings at the same course on the same
    /// day, an abandoned card replaced by another, a market for the wrong leg of a
    /// double-header. If the horses do not overlap it is not the same race,
    /// whatever the metadata says.
    public var minimumRunnerOverlap: Double

    /// The largest edit distance accepted when falling back to fuzzy names.
    ///
    /// Two, i.e. typo-sized. Horses in the same race can have genuinely similar
    /// names, so a larger figure buys mismatches rather than matches.
    public var maximumNameDistance: Int

    public init(
        startTimeWindowMinutes: Double = 6,
        minimumRunnerOverlap: Double = 0.6,
        maximumNameDistance: Int = 2
    ) {
        self.startTimeWindowMinutes = startTimeWindowMinutes
        self.minimumRunnerOverlap = minimumRunnerOverlap
        self.maximumNameDistance = maximumNameDistance
    }

    public static let `default` = MatchingTolerances()

    /// Cloth numbers and exact names only. Useful for asserting that a fixture
    /// matches cleanly without the fuzzy pass covering for it.
    public static let strictNames = MatchingTolerances(maximumNameDistance: 0)
}
