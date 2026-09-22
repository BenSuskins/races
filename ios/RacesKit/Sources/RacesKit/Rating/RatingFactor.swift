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
        }
    }

    /// Why this factor carries the weight it does — and, for the four that ship
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

    public init(race: Race, strikeRates: (any StrikeRateProviding)? = nil) {
        self.race = race
        self.strikeRates = strikeRates
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
