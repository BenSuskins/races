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

public struct RunnerAssessment: Codable, Hashable, Sendable, Identifiable {
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

    /// Expected value per unit staked: `p(model) × odds - 1`.
    public var valueEdge: Double? {
        guard let marketBackPrice, marketBackPrice > 1 else { return nil }
        return winProbability * marketBackPrice - 1
    }

    /// Difference between the model's probability and the de-vigged market view.
    public var probabilityEdge: Double? {
        guard let marketProbability else { return nil }
        return winProbability - marketProbability
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

public struct RaceAssessment: Codable, Hashable, Sendable {
    public let raceID: String
    public let generatedAt: Date
    public let modelVersion: String
    public let weightsID: String
    public let marketSource: MarketSnapshot.Source?
    public let marketCoverage: Double
    public let isMarketDelayed: Bool
    public let runners: [RunnerAssessment]
    public let confidence: AssessmentConfidence

    /// The snapshot of model inputs available at tip time. The outcome is deliberately
    /// absent and is attached only after the race settles.
    public let trainingSnapshot: TrainingRaceSnapshot?

    /// Minimum positive expected value required before the model is allowed to
    /// replace the ordinary highest-probability selection.
    public let minimumValueEdge: Double
    public let minimumValueProbability: Double

    public var selection: RunnerAssessment? {
        guard !runners.isEmpty else { return nil }
        guard !isFormOnly else { return runners.first }

        let candidates = runners.filter { runner in
            guard let edge = runner.valueEdge else { return false }
            return edge >= minimumValueEdge
                && runner.winProbability >= minimumValueProbability
        }

        return candidates.max { lhs, rhs in
            if lhs.valueEdge != rhs.valueEdge {
                return (lhs.valueEdge ?? -.infinity) < (rhs.valueEdge ?? -.infinity)
            }
            return lhs.winProbability < rhs.winProbability
        } ?? runners.first
    }

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

    /// The runner the model gives the best chance, whatever its price.
    public var topRated: RunnerAssessment? {
        runners.max { $0.winProbability < $1.winProbability }
    }

    /// The selection is a value pick rather than the model's most likely winner:
    /// its price beat both thresholds, so it was preferred over `topRated`.
    ///
    /// Worth saying on screen every time, because the card shows the selection's
    /// win probability and the runner list shows everyone's, and without it a
    /// 15% pick sitting above a 35% runner reads as a bug.
    public var isValuePick: Bool {
        guard !isFormOnly, let selection, let topRated else { return false }
        return selection.horseID != topRated.horseID
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
        trainingSnapshot: TrainingRaceSnapshot? = nil,
        minimumValueEdge: Double = 0.05,
        minimumValueProbability: Double = 0.08
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
        self.minimumValueEdge = minimumValueEdge
        self.minimumValueProbability = minimumValueProbability
    }
}
