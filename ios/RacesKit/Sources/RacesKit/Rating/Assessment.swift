import Foundation

/// What one factor did to one runner's chance.
public struct FactorContribution: Codable, Hashable, Sendable, Identifiable {
    public let factor: FactorID
    public let label: String
    /// What the factor read, e.g. "OR 82".
    public let detail: String
    /// The runner's standing within this race on this factor, or nil when the
    /// factor had nothing to say.
    public let zScore: Double?
    public let weight: Double
    /// Effect on the win chance, computed leave-one-out: the difference between
    /// this runner's probability and what it would have been with this factor
    /// neutralised.
    public let probabilityDelta: Double
    public let availability: FactorAvailability

    public var id: FactorID { factor }

    public enum Direction: Hashable, Sendable {
        case positive, negative, neutral
    }

    public var direction: Direction {
        guard availability.isAvailable else { return .neutral }
        if probabilityDelta > 0.001 { return .positive }
        if probabilityDelta < -0.001 { return .negative }
        return .neutral
    }

    public init(
        factor: FactorID,
        detail: String,
        zScore: Double?,
        weight: Double,
        probabilityDelta: Double,
        availability: FactorAvailability
    ) {
        self.factor = factor
        self.label = factor.label
        self.detail = detail
        self.zScore = zScore
        self.weight = weight
        self.probabilityDelta = probabilityDelta
        self.availability = availability
    }
}

/// How much to trust a race's assessment. Not a claim about the horse — a claim
/// about how much the model actually had to work with.
public enum AssessmentConfidence: String, Codable, Hashable, Sendable, CaseIterable {
    case low, medium, high

    public var displayName: String {
        switch self {
        case .low: return "Low confidence"
        case .medium: return "Medium confidence"
        case .high: return "High confidence"
        }
    }
}

public struct RunnerAssessment: Hashable, Sendable, Identifiable {
    public let horseID: String
    public let horseName: String
    public let clothNumber: Int?
    /// The market's own view, de-vigged. Nil when there was no usable market.
    public let marketProbability: Double?
    public let marketBackPrice: Double?
    /// The weighted sum of standardised factors. Zero is "exactly average for this
    /// race", which is also what a runner we know nothing about scores.
    public let formScore: Double
    public let winProbability: Double
    public let contributions: [FactorContribution]

    public var id: String { horseID }

    /// The price at which this chance would be a break-even bet.
    public var fairOdds: Double {
        winProbability > 0 ? 1 / winProbability : .infinity
    }

    /// How far the available price is from our fair price. Positive means we think
    /// the runner is bigger than it should be. Nil without a market.
    public var valueEdge: Double? {
        guard let marketBackPrice, marketBackPrice > 1 else { return nil }
        return winProbability * marketBackPrice - 1
    }

    public init(
        horseID: String,
        horseName: String,
        clothNumber: Int?,
        marketProbability: Double?,
        marketBackPrice: Double?,
        formScore: Double,
        winProbability: Double,
        contributions: [FactorContribution]
    ) {
        self.horseID = horseID
        self.horseName = horseName
        self.clothNumber = clothNumber
        self.marketProbability = marketProbability
        self.marketBackPrice = marketBackPrice
        self.formScore = formScore
        self.winProbability = winProbability
        self.contributions = contributions
    }
}

/// A whole race, rated.
public struct RaceAssessment: Hashable, Sendable {
    public let raceID: String
    public let generatedAt: Date
    /// The algorithm's identity, stamped onto every tip so that changing the model
    /// cannot silently invalidate the accuracy history.
    public let modelVersion: String
    public let weightsID: String
    public let marketSource: MarketSnapshot.Source?
    public let marketCoverage: Double
    public let isMarketDelayed: Bool
    /// Runners in rank order, most fancied first.
    public let runners: [RunnerAssessment]
    public let confidence: AssessmentConfidence

    public var selection: RunnerAssessment? { runners.first }

    /// True when no market anchored this race, so the rating rests on form alone.
    /// The UI says so rather than presenting a thinner assessment as an equal one.
    public var isFormOnly: Bool { marketSource == nil }

    /// The market's own favourite, for the comparison that matters most: if the
    /// model cannot beat simply backing this, it is not doing anything.
    public var marketFavourite: RunnerAssessment? {
        runners
            .filter { $0.marketProbability != nil }
            .max { ($0.marketProbability ?? 0) < ($1.marketProbability ?? 0) }
    }

    /// Whether the model's selection is just the favourite. When it is, the model
    /// contributed nothing to this race — which is worth tracking separately,
    /// because all of its actual information is in the races where it disagreed.
    public var agreesWithMarket: Bool? {
        guard let selection, let favourite = marketFavourite else { return nil }
        return selection.horseID == favourite.horseID
    }

    public init(
        raceID: String,
        generatedAt: Date,
        modelVersion: String,
        weightsID: String,
        marketSource: MarketSnapshot.Source?,
        marketCoverage: Double,
        isMarketDelayed: Bool,
        runners: [RunnerAssessment],
        confidence: AssessmentConfidence
    ) {
        self.raceID = raceID
        self.generatedAt = generatedAt
        self.modelVersion = modelVersion
        self.weightsID = weightsID
        self.marketSource = marketSource
        self.marketCoverage = marketCoverage
        self.isMarketDelayed = isMarketDelayed
        self.runners = runners
        self.confidence = confidence
    }
}
