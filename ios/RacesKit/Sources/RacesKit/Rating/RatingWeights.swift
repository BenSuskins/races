import Foundation

/// Every tunable number in the model, in one place.
///
/// `Codable` so the back-test can sweep them, and so a future build could ship
/// refitted weights as data rather than as a release.
///
/// **None of these are fitted.** They are reasoned starting points, and
/// `docs/algorithm.md` says so alongside the reasoning. The back-test exists to
/// replace them with something earned.
public struct RatingWeights: Codable, Hashable, Sendable {

    /// Stamped onto every tip. Change the numbers, change the id — otherwise
    /// tuning silently invalidates the accuracy history, which is very hard to
    /// notice later and impossible to repair.
    public var id: String

    /// α — how much of the market's shape to keep. 1.0 takes it as given; below 1
    /// flattens it if the back-test ever shows we should trust it less.
    public var marketExponent: Double

    /// β — how far the model may disagree with the market.
    ///
    /// **This is the single most important number in the model.** At `0` the
    /// output *is* the market, which is what makes "does any of this help?" a
    /// measurement rather than an opinion.
    public var formInfluence: Double

    /// β when there is no market to anchor to, so form has to carry the race.
    public var formInfluenceNoMarket: Double

    /// z-scores are clipped to ±this, so one freak value cannot dominate a race.
    public var clip: Double

    public var overroundMethod: Overround.Method

    /// The share of a field that must be priced before the market is trusted at
    /// all. Below it the market is discarded wholesale rather than used to anchor
    /// part of a race — a book missing three runners is not a book.
    public var minimumMarketCoverage: Double

    /// Per-factor weights, keyed by `FactorID.rawValue` so the JSON stays readable
    /// and stable. A factor absent from the dictionary contributes nothing.
    public var factorWeights: [String: Double]

    public var formDecay: Double
    public var formPoints: [String: Double]
    public var formSeasonBreakPenalty: Double
    public var formLongBreakPenalty: Double
    public var formMaxRuns: Int

    /// Strike-rate factors stay silent until the archive holds at least this many
    /// runs for a given jockey or trainer.
    public var minimumStrikeRateSample: Int

    /// Minimum model expected value required to prefer a priced runner over the
    /// ordinary highest-probability selection.
    public var minimumValueEdge: Double

    /// Minimum model win probability for a value selection. This prevents a very
    /// large price from winning selection on a tiny model probability alone.
    public var minimumValueProbability: Double

    public init(
        id: String,
        marketExponent: Double = 1.0,
        formInfluence: Double = 0.35,
        formInfluenceNoMarket: Double = 0.90,
        clip: Double = 2.5,
        overroundMethod: Overround.Method = .proportional,
        minimumMarketCoverage: Double = 0.80,
        factorWeights: [String: Double],
        formDecay: Double = 0.75,
        formPoints: [String: Double] = FormScorer.defaultPoints,
        formSeasonBreakPenalty: Double = 0.80,
        formLongBreakPenalty: Double = 0.50,
        formMaxRuns: Int = 6,
        minimumStrikeRateSample: Int = 30,
        minimumValueEdge: Double = 0.05,
        minimumValueProbability: Double = 0.08
    ) {
        self.id = id
        self.marketExponent = marketExponent
        self.formInfluence = formInfluence
        self.formInfluenceNoMarket = formInfluenceNoMarket
        self.clip = clip
        self.overroundMethod = overroundMethod
        self.minimumMarketCoverage = minimumMarketCoverage
        self.factorWeights = factorWeights
        self.formDecay = formDecay
        self.formPoints = formPoints
        self.formSeasonBreakPenalty = formSeasonBreakPenalty
        self.formLongBreakPenalty = formLongBreakPenalty
        self.formMaxRuns = formMaxRuns
        self.minimumStrikeRateSample = minimumStrikeRateSample
        self.minimumValueEdge = minimumValueEdge
        self.minimumValueProbability = minimumValueProbability
    }

    public func weight(for id: FactorID) -> Double {
        factorWeights[id.rawValue] ?? 0
    }

    public var scorer: FormScorer {
        FormScorer(
            points: formPoints,
            decay: formDecay,
            seasonBreakPenalty: formSeasonBreakPenalty,
            longBreakPenalty: formLongBreakPenalty,
            maxRuns: formMaxRuns
        )
    }

    private static let baseFactorWeights: [String: Double] = [
        FactorID.officialRating.rawValue: 0.30,
        FactorID.handicapBandPosition.rawValue: 0.20,
        FactorID.recentForm.rawValue: 0.25,
        FactorID.wonLastTime.rawValue: 0.10,
        FactorID.completionRate.rawValue: 0.08,
        FactorID.daysSinceLastRun.rawValue: 0.06,
        FactorID.age.rawValue: 0.04,
        FactorID.weightCarried.rawValue: 0.02,
        FactorID.draw.rawValue: 0.00,
        FactorID.headgear.rawValue: 0.00,
        FactorID.jockeyStrikeRate.rawValue: 0.00,
        FactorID.trainerStrikeRate.rawValue: 0.00,
        FactorID.jockeySurfaceStrikeRate.rawValue: 0.00,
        FactorID.trainerSurfaceStrikeRate.rawValue: 0.00,
        FactorID.jockeyRaceTypeStrikeRate.rawValue: 0.00,
        FactorID.trainerRaceTypeStrikeRate.rawValue: 0.00,
        FactorID.horseGoingPlaceRate.rawValue: 0.00,
        FactorID.jockeyGoingStrikeRate.rawValue: 0.00,
        FactorID.trainerGoingStrikeRate.rawValue: 0.00,
        FactorID.jockeyRecentStrikeRate.rawValue: 0.00,
        FactorID.trainerRecentStrikeRate.rawValue: 0.00,
    ]

    /// The original market-anchored configuration, retained for back-test
    /// comparisons and historical provenance.
    public static let v1 = RatingWeights(
        id: "v1",
        factorWeights: baseFactorWeights,
        minimumValueEdge: 0.00,
        minimumValueProbability: 0.00
    )

    /// v1's probabilities with a value-aware selection layer: a meaningful
    /// positive EV and an 8% model win probability before preferring a
    /// non-favourite. Kept for the tips it stamped and for back-tests.
    public static let v2 = RatingWeights(
        id: "v2",
        factorWeights: baseFactorWeights,
        minimumValueEdge: 0.05,
        minimumValueProbability: 0.08
    )

    /// Current configuration: v2's probabilities, and the tip is the runner the
    /// model gives the best chance of winning.
    ///
    /// The value layer is off through its own threshold rather than a new field:
    /// a value candidate needs a model probability of at least
    /// `minimumValueProbability`, and at 1 no runner in a real field clears it,
    /// so `selection` always falls through to the highest probability. The
    /// server's `rating.V3` is the same numbers.
    public static let v3 = RatingWeights(
        id: "v3",
        factorWeights: baseFactorWeights,
        minimumValueEdge: 0.05,
        minimumValueProbability: 1
    )

    /// True when no runner can qualify as a value pick, so the tip is always
    /// the most likely winner.
    public var picksMostLikelyWinner: Bool { minimumValueProbability >= 1 }

    /// The market, unmodified. Not a real configuration — it is the control the
    /// back-test measures everything else against.
    public static let marketOnly = RatingWeights(
        id: "market-only",
        formInfluence: 0,
        formInfluenceNoMarket: 0,
        factorWeights: [:]
    )
}
