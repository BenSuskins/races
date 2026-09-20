import Foundation

/// How a tip turned out.
public enum TipOutcome: Codable, Hashable, Sendable {
    case won(betfairSP: Double?)
    case lost(position: Int?, betfairSP: Double?)
    /// The selection was withdrawn. A **void** bet, not a losing one.
    case nonRunner
    case abandoned
    /// We have not managed to find a result yet, and are still trying.
    case unresolved(lastCheckedAt: Date, attempts: Int)
    /// We gave up looking. Excluded from every metric, but counted and shown.
    case expired(at: Date)

    /// Whether this tip contributes to strike rate and ROI. Only won and lost do.
    public var isSettled: Bool {
        switch self {
        case .won, .lost: return true
        case .nonRunner, .abandoned, .unresolved, .expired: return false
        }
    }

    /// Void: the race happened, but our selection did not take part in it.
    /// Excluded from the denominator — counting a non-runner as a loss would
    /// understate the model for something it had no part in.
    public var isVoid: Bool {
        switch self {
        case .nonRunner, .abandoned: return true
        default: return false
        }
    }

    public var isWin: Bool {
        if case .won = self { return true }
        return false
    }

    public var betfairSP: Double? {
        switch self {
        case .won(let sp): return sp
        case .lost(_, let sp): return sp
        default: return nil
        }
    }
}

/// What the market favourite did in the same race.
///
/// Recorded alongside the tip so the baseline comparison is available without
/// re-fetching a result we may never be able to fetch again — the free results
/// endpoint only covers today.
public struct FavouriteOutcome: Codable, Hashable, Sendable {
    public let horseID: String
    public let won: Bool
    public let betfairSP: Double?

    public init(horseID: String, won: Bool, betfairSP: Double?) {
        self.horseID = horseID
        self.won = won
        self.betfairSP = betfairSP
    }
}

/// A tip, frozen at the moment it was made.
///
/// Everything needed to judge it later is copied in rather than referenced,
/// including the model version and the explanation. Re-deriving a tip after the
/// fact would measure today's model against yesterday's races, which is a
/// comfortable way to be wrong about your own accuracy.
public struct TipRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { raceID }

    public let raceID: String
    public let raceDate: String
    public let offAt: Date?
    public let courseName: String
    public let raceName: String
    public let raceType: RaceType
    public let fieldSizeAtTip: Int

    public let selectionHorseID: String
    public let selectionHorseName: String
    public let predictedProbability: Double
    public let marketProbabilityAtTip: Double?
    public let marketBackPriceAtTip: Double?
    public let marketFavouriteHorseID: String?
    /// Whether the tip was simply the favourite. When it was, the model
    /// contributed nothing to that race — which is exactly why it is tracked.
    public let agreedWithFavourite: Bool?
    public let wasFormOnly: Bool
    public let confidence: AssessmentConfidence

    public let modelVersion: String
    public let weightsID: String
    public let contributions: [FactorContribution]

    public let createdAt: Date
    /// Set once, when the tip enters the window before the off. After that the
    /// record is immutable.
    public var sealedAt: Date?
    public var outcome: TipOutcome?
    public var favouriteOutcome: FavouriteOutcome?

    public var isSealed: Bool { sealedAt != nil }

    public init(
        raceID: String,
        raceDate: String,
        offAt: Date?,
        courseName: String,
        raceName: String,
        raceType: RaceType,
        fieldSizeAtTip: Int,
        selectionHorseID: String,
        selectionHorseName: String,
        predictedProbability: Double,
        marketProbabilityAtTip: Double?,
        marketBackPriceAtTip: Double?,
        marketFavouriteHorseID: String?,
        agreedWithFavourite: Bool?,
        wasFormOnly: Bool,
        confidence: AssessmentConfidence,
        modelVersion: String,
        weightsID: String,
        contributions: [FactorContribution],
        createdAt: Date,
        sealedAt: Date? = nil,
        outcome: TipOutcome? = nil,
        favouriteOutcome: FavouriteOutcome? = nil
    ) {
        self.raceID = raceID
        self.raceDate = raceDate
        self.offAt = offAt
        self.courseName = courseName
        self.raceName = raceName
        self.raceType = raceType
        self.fieldSizeAtTip = fieldSizeAtTip
        self.selectionHorseID = selectionHorseID
        self.selectionHorseName = selectionHorseName
        self.predictedProbability = predictedProbability
        self.marketProbabilityAtTip = marketProbabilityAtTip
        self.marketBackPriceAtTip = marketBackPriceAtTip
        self.marketFavouriteHorseID = marketFavouriteHorseID
        self.agreedWithFavourite = agreedWithFavourite
        self.wasFormOnly = wasFormOnly
        self.confidence = confidence
        self.modelVersion = modelVersion
        self.weightsID = weightsID
        self.contributions = contributions
        self.createdAt = createdAt
        self.sealedAt = sealedAt
        self.outcome = outcome
        self.favouriteOutcome = favouriteOutcome
    }

    /// Build a tip from a rated race.
    public init?(assessment: RaceAssessment, race: Race, now: Date) {
        guard let selection = assessment.selection else { return nil }
        self.init(
            raceID: assessment.raceID,
            raceDate: race.date,
            offAt: race.offDateTime,
            courseName: race.courseName,
            raceName: race.name,
            raceType: race.type,
            fieldSizeAtTip: race.runnerCount,
            selectionHorseID: selection.horseID,
            selectionHorseName: selection.horseName,
            predictedProbability: selection.winProbability,
            marketProbabilityAtTip: selection.marketProbability,
            marketBackPriceAtTip: selection.marketBackPrice,
            marketFavouriteHorseID: assessment.marketFavourite?.horseID,
            agreedWithFavourite: assessment.agreesWithMarket,
            wasFormOnly: assessment.isFormOnly,
            confidence: assessment.confidence,
            modelVersion: assessment.modelVersion,
            weightsID: assessment.weightsID,
            contributions: selection.contributions,
            createdAt: now
        )
    }
}
