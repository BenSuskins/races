import Foundation

/// What one factor did to one runner's chance.
public struct FactorContribution: Codable, Hashable, Sendable, Identifiable {
    public let factor: FactorID
    public let label: String
    public let detail: String
    public let zScore: Double?
    public let weight: Double
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
    public let marketProbability: Double?
    public let marketBackPrice: Double?
    public let formScore: Double
    public let winProbability: Double
    public let contributions: [FactorContribution]

    public var id: String { horseID }

    public var fairOdds: Double {
        winProbability > 0 ? 1 / winProbability : .infinity
    }

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
    public let modelVersion: String
    public let weightsID: String
    public let marketSource: MarketSnapshot.Source?
    public let marketCoverage: Double
    public let isMarketDelayed: Bool
    public let runners: [RunnerAssessment]
    public let confidence: AssessmentConfidence
    /// Frozen factor z-scores and market probabilities used to make this assessment.
    /// It is retained so the on-device trainer can learn from the race later without
    /// re-running today's model against yesterday's inputs.
    public let trainingSnapshot: TrainingRaceSnapshot?

    public var selection: RunnerAssessment? { runners.first }
    public var isFormOnly: Bool { marketSource == nil }

    public var marketFavourite: RunnerAssessment? {
        runners
            .filter { $0.marketProbability != nil }
            .max { ($0.marketProbability ?? 0) < ($1.marketProbability ?? 0) }
    }

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
        confidence: AssessmentConfidence,
        trainingSnapshot: TrainingRaceSnapshot? = nil
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
        self.trainingSnapshot = trainingSnapshot
    }
}
