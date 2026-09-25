import Foundation

/// The factors the model can use. Stable raw values — they are stamped into
/// stored tips, so renaming one breaks the accuracy history.
public enum FactorID: String, Codable, Hashable, Sendable, CaseIterable {
    case officialRating
    case handicapBandPosition
    case recentForm
    case wonLastTime
    case completionRate
    case daysSinceLastRun
    case age
    case weightCarried
    case draw
    case headgear
    case jockeyStrikeRate
    case trainerStrikeRate
    case jockeySurfaceStrikeRate
    case trainerSurfaceStrikeRate
    case jockeyRaceTypeStrikeRate
    case trainerRaceTypeStrikeRate
    case jockeyGoingStrikeRate
    case trainerGoingStrikeRate
    case horseGoingPlaceRate
    case jockeyRecentStrikeRate
    case trainerRecentStrikeRate
    case jockeyTrainerStrikeRate

    public var label: String {
        switch self {
        case .officialRating: return "Official rating"
        case .handicapBandPosition: return "Position in the handicap"
        case .recentForm: return "Recent form"
        case .wonLastTime: return "Won last time out"
        case .completionRate: return "Completion record"
        case .daysSinceLastRun: return "Days since last run"
        case .age: return "Age"
        case .weightCarried: return "Weight carried"
        case .draw: return "Draw"
        case .headgear: return "Headgear"
        case .jockeyStrikeRate: return "Jockey strike rate"
        case .trainerStrikeRate: return "Trainer strike rate"
        case .jockeySurfaceStrikeRate: return "Jockey strike rate by surface"
        case .trainerSurfaceStrikeRate: return "Trainer strike rate by surface"
        case .jockeyRaceTypeStrikeRate: return "Jockey strike rate by race type"
        case .trainerRaceTypeStrikeRate: return "Trainer strike rate by race type"
        case .jockeyGoingStrikeRate: return "Jockey strike rate by going"
        case .trainerGoingStrikeRate: return "Trainer strike rate by going"
        case .horseGoingPlaceRate: return "Horse record by going"
        case .jockeyRecentStrikeRate: return "Jockey recent strike rate"
        case .trainerRecentStrikeRate: return "Trainer recent strike rate"
        case .jockeyTrainerStrikeRate: return "Jockey and trainer record together"
        }
    }

    /// One sentence on what this factor reads, in the terms a racegoer uses.
    ///
    /// Kept here beside `label` rather than in the app, so the Model screen and
    /// the weights it describes cannot drift apart, and so the Linux job covers
    /// the pairing.
    public var summary: String {
        switch self {
        case .officialRating:
            return "The handicapper's number. The strongest thing the free tier gives us."
        case .handicapBandPosition:
            return "Where the rating sits inside the race's own band — well in at the top, struggling at the bottom."
        case .recentForm:
            return "The form string, read right to left and weighted toward the most recent run."
        case .wonLastTime:
            return "Whether the last completed run was a win."
        case .completionRate:
            return "How often the horse finishes at all. It means far more over fences than on the Flat."
        case .daysSinceLastRun:
            return "Time off, scored as a bell rather than a line — a fortnight is better than three days or three months."
        case .age:
            return "Age against the race's own age band."
        case .weightCarried:
            return "Pounds carried, negated so less is better."
        case .draw:
            return "Stall number."
        case .headgear:
            return "Blinkers, a visor, a hood, cheekpieces."
        case .jockeyStrikeRate:
            return "The jockey's win rate in the app's own archive, shrunk toward the field average."
        case .trainerStrikeRate:
            return "The trainer's win rate in the app's own archive, shrunk toward the field average."
        case .jockeySurfaceStrikeRate:
            return "The jockey's win rate on this surface, shrunk toward the jockey's overall record."
        case .trainerSurfaceStrikeRate:
            return "The trainer's win rate on this surface, shrunk toward the trainer's overall record."
        case .jockeyRaceTypeStrikeRate:
            return "The jockey's win rate in this type of race, shrunk toward the jockey's overall record."
        case .trainerRaceTypeStrikeRate:
            return "The trainer's win rate in this type of race, shrunk toward the trainer's overall record."
        case .jockeyGoingStrikeRate:
            return "The jockey's win rate on similar ground, shrunk toward the jockey's overall record."
        case .trainerGoingStrikeRate:
            return "The trainer's win rate on similar ground, shrunk toward the trainer's overall record."
        case .horseGoingPlaceRate:
            return "The horse's place rate on similar ground, shrunk toward its general record."
        case .jockeyRecentStrikeRate:
            return "The jockey's win rate from the latest 50 dated rides, shrunk toward the global record."
        case .trainerRecentStrikeRate:
            return "The trainer's win rate from the latest 50 dated runners, shrunk toward the global record."
        case .jockeyTrainerStrikeRate:
            return "The win rate when this jockey rides for this trainer, adjusted toward their individual records."
        }
    }

    /// Why this factor carries the weight it does — and, for the factors that ship
    /// at zero, why the code is present and switched off.
    ///
    /// Shipping a factor at zero weight with its reasoning attached is a
    /// deliberate choice: inventing a draw-bias table we cannot substantiate
    /// would produce confident nonsense, and deleting the factor would lose the
    /// work. This is the text that makes the zero legible rather than looking
    /// like a bug.
    public var rationale: String? {
        switch self {
        case .draw:
            return "Draw bias is real, but it is a course × distance × going × field-size interaction. Without a bias table it is noise, so the code ships switched off."
        case .headgear:
            return "The signal is *first-time* headgear, and the free tier has no headgear history to detect it with."
        case .jockeyStrikeRate, .trainerStrikeRate:
            return "Legitimate, but derived from an archive that starts empty. It switches on once enough race days have been collected."
        case .jockeySurfaceStrikeRate, .trainerSurfaceStrikeRate:
            return "Surface cells need at least 30 runs. The default weight is zero until walk-forward replay supports it."
        case .jockeyRaceTypeStrikeRate, .trainerRaceTypeStrikeRate:
            return "Race-type cells need at least 30 runs. The default weight is zero until walk-forward replay supports it."
        case .jockeyGoingStrikeRate, .trainerGoingStrikeRate:
            return "Going cells need at least 30 runs. The default weight is zero until walk-forward replay supports it."
        case .horseGoingPlaceRate:
            return "The archive needs at least three completed runs in a going bucket. Its default weight is zero until replay supports it."
        case .jockeyRecentStrikeRate, .trainerRecentStrikeRate:
            return "The recent window needs at least 30 dated runs. The default weight is zero until walk-forward replay supports it."
        case .jockeyTrainerStrikeRate:
            return "The pair needs 30 runs and both individual records need enough history. Its default weight is zero until coverage and walk-forward evidence support it."
        case .weightCarried:
            return "Near zero on purpose: in a handicap, weight is the handicapper's equaliser, so it substantially double-counts the official rating."
        case .officialRating, .handicapBandPosition, .recentForm, .wonLastTime,
             .completionRate, .daysSinceLastRun, .age:
            return nil
        }
    }
}

/// Why a factor produced no value. The distinction matters in the UI: "we don't
/// know" and "this doesn't apply here" and "your plan doesn't include this" are
/// three different sentences, and none of them is an error.
public enum FactorAvailability: Codable, Hashable, Sendable {
    case available
    /// The data is missing for this runner — an unraced horse has no form.
    case missingData(String)
    /// The factor does not apply to this race — the draw means nothing over fences.
    case notApplicable(String)
    /// A paid tier would provide it.
    case requiresPaidTier(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case .available: return nil
        case .missingData(let reason), .notApplicable(let reason), .requiresPaidTier(let reason):
            return reason
        }
    }
}

/// One factor's raw reading for one runner, before standardisation.
public struct FactorValue: Hashable, Sendable {
    /// Higher is always better, for every factor. Factors where "less is more" —
    /// weight carried, say — negate at source, so the combination step never has
    /// to know which way round a given factor runs.
    public let raw: Double?
    /// What to show the user, e.g. "OR 82, 8 lb above the race average".
    public let display: String
    public let availability: FactorAvailability

    public init(raw: Double?, display: String, availability: FactorAvailability) {
        self.raw = raw
        self.display = display
        self.availability = availability
    }

    public static func value(_ raw: Double, _ display: String) -> FactorValue {
        FactorValue(raw: raw, display: display, availability: .available)
    }

    public static func missing(_ reason: String, display: String = "—") -> FactorValue {
        FactorValue(raw: nil, display: display, availability: .missingData(reason))
    }

    public static func notApplicable(_ reason: String, display: String = "—") -> FactorValue {
        FactorValue(raw: nil, display: display, availability: .notApplicable(reason))
    }

    public static func requiresPaidTier(_ reason: String, display: String = "—") -> FactorValue {
        FactorValue(raw: nil, display: display, availability: .requiresPaidTier(reason))
    }
}

/// Everything a factor may look at beyond the runner itself.
public struct FactorContext: Sendable {
    public let race: Race
    /// Strike rates accumulated from the app's own archive. Nil until there is
    /// enough history to be worth consulting.
    public let strikeRates: (any StrikeRateProviding)?
    public let surfaceStrikeRates: (any SurfaceStrikeRateProviding)?
    public let raceTypeStrikeRates: (any RaceTypeStrikeRateProviding)?
    public let goingStrikeRates: (any GoingStrikeRateProviding)?
    public let horseGoingRates: (any HorseGoingProviding)?
    public let recentStrikeRates: (any RecentStrikeRateProviding)?
    public let jockeyTrainerStrikeRates: (any JockeyTrainerStrikeRateProviding)?

    public init(race: Race, strikeRates: (any StrikeRateProviding)? = nil, surfaceStrikeRates: (any SurfaceStrikeRateProviding)? = nil, raceTypeStrikeRates: (any RaceTypeStrikeRateProviding)? = nil, goingStrikeRates: (any GoingStrikeRateProviding)? = nil, horseGoingRates: (any HorseGoingProviding)? = nil, recentStrikeRates: (any RecentStrikeRateProviding)? = nil, jockeyTrainerStrikeRates: (any JockeyTrainerStrikeRateProviding)? = nil) {
        self.race = race
        self.strikeRates = strikeRates
        self.surfaceStrikeRates = surfaceStrikeRates ?? (strikeRates as? any SurfaceStrikeRateProviding)
        self.raceTypeStrikeRates = raceTypeStrikeRates ?? (strikeRates as? any RaceTypeStrikeRateProviding)
        self.goingStrikeRates = goingStrikeRates ?? (strikeRates as? any GoingStrikeRateProviding)
        self.horseGoingRates = horseGoingRates ?? (strikeRates as? any HorseGoingProviding)
        self.recentStrikeRates = recentStrikeRates ?? (strikeRates as? any RecentStrikeRateProviding)
        self.jockeyTrainerStrikeRates = jockeyTrainerStrikeRates ?? (strikeRates as? any JockeyTrainerStrikeRateProviding)
    }
}

/// A single, independently testable input to the rating.
///
/// Factors return **raw values only**. Standardising needs the whole field, so it
/// happens centrally in `Standardiser` — which also makes each factor a two-line
/// unit test rather than a statistical exercise.
public protocol RatingFactor: Sendable {
    var id: FactorID { get }
    func value(for runner: Runner, in context: FactorContext) -> FactorValue
}

/// A win record, for strike rates derived from the app's own accumulated results.
public struct StrikeRate: Codable, Hashable, Sendable {
    public let runs: Int
    public let wins: Int

    public init(runs: Int, wins: Int) {
        self.runs = runs
        self.wins = wins
    }

    public var raw: Double? {
        guard runs > 0 else { return nil }
        return Double(wins) / Double(runs)
    }

    /// Shrunk toward a prior, so a trainer with one win from one run is not
    /// credited with a 100% strike rate.
    ///
    /// `strength` is the number of notional prior runs; at 20, a record of 1 from 1
    /// barely moves off the prior, while 40 from 200 dominates it. Without this the
    /// factor would be loudest exactly where the evidence is thinnest.
    public func smoothed(towards prior: Double, strength: Double = 20) -> Double {
        let total = Double(runs) + strength
        guard total > 0 else { return prior }
        return (Double(wins) + prior * strength) / total
    }
}

/// Supplies strike rates from the on-device archive. Implemented alongside the
/// results store; nil here until there is history worth reading.
public protocol StrikeRateProviding: Sendable {
    func jockeyStrikeRate(id: String) -> StrikeRate?
    func trainerStrikeRate(id: String) -> StrikeRate?
    /// The population mean to shrink toward. Roughly 1/fieldSize in the long run.
    var baselineStrikeRate: Double { get }
}

public protocol SurfaceStrikeRateProviding: StrikeRateProviding {
    func jockeySurfaceStrikeRate(id: String, surface: Surface) -> StrikeRate?
    func trainerSurfaceStrikeRate(id: String, surface: Surface) -> StrikeRate?
}

public protocol RaceTypeStrikeRateProviding: StrikeRateProviding {
    func jockeyRaceTypeStrikeRate(id: String, raceType: RaceType) -> StrikeRate?
    func trainerRaceTypeStrikeRate(id: String, raceType: RaceType) -> StrikeRate?
}

public protocol GoingStrikeRateProviding: StrikeRateProviding {
    func jockeyGoingStrikeRate(id: String, surface: Surface, bucket: HorseGoingBucket) -> StrikeRate?
    func trainerGoingStrikeRate(id: String, surface: Surface, bucket: HorseGoingBucket) -> StrikeRate?
}

public protocol RecentStrikeRateProviding: StrikeRateProviding {
    func jockeyRecentStrikeRate(id: String) -> StrikeRate?
    func trainerRecentStrikeRate(id: String) -> StrikeRate?
}

public protocol JockeyTrainerStrikeRateProviding: StrikeRateProviding {
    func jockeyTrainerStrikeRate(jockeyID: String, trainerID: String) -> StrikeRate?
}

public struct HorseGoingPlaceRate: Codable, Hashable, Sendable {
    public let runs: Int
    public let places: Int

    public init(runs: Int, places: Int) {
        self.runs = runs
        self.places = places
    }

    public func smoothed(towards prior: Double, strength: Double = 5) -> Double {
        (Double(places) + prior * strength) / (Double(runs) + strength)
    }
}

public protocol HorseGoingProviding: Sendable {
    func horseGoingRate(horseID: String, surface: Surface, bucket: HorseGoingBucket) -> HorseGoingPlaceRate?
    func horseOverallPlaceRate(horseID: String) -> HorseGoingPlaceRate?
}
