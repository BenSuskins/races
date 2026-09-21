import Foundation

/// Which day's card to fetch. The free tier offers only these two.
public enum RaceDay: String, Codable, Sendable, CaseIterable {
    case today
    case tomorrow

    /// The provider's query value for `?day=`.
    public var queryValue: String { rawValue }
}

/// State of the ground.
///
/// Turf and all-weather use different vocabularies — turf runs firm→heavy, AW runs
/// fast→slow — so both are represented here and `isAllWeather` distinguishes them.
/// Unrecognised strings become `.unknown` rather than throwing: going descriptions
/// vary by course and a novel one must not cost us the racecard.
public enum Going: String, Codable, Sendable, CaseIterable {
    case heavy, soft, goodToSoft, good, goodToFirm, firm
    case slow, standardToSlow, standard, standardToFast, fast
    case unknown

    public init(raw: String?) {
        guard let raw else { self = .unknown; return }
        let key = raw.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch key {
        case "heavy": self = .heavy
        case "soft": self = .soft
        case "goodtosoft", "gdsft", "goodtosoftgoodinplaces": self = .goodToSoft
        case "good", "gd": self = .good
        case "goodtofirm", "gdfm": self = .goodToFirm
        case "firm", "fm", "hard": self = .firm
        case "slow": self = .slow
        case "standardtoslow": self = .standardToSlow
        case "standard", "std": self = .standard
        case "standardtofast": self = .standardToFast
        case "fast": self = .fast
        default: self = .unknown
        }
    }

    public var isAllWeather: Bool {
        switch self {
        case .slow, .standardToSlow, .standard, .standardToFast, .fast: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .heavy: return "Heavy"
        case .soft: return "Soft"
        case .goodToSoft: return "Good to Soft"
        case .good: return "Good"
        case .goodToFirm: return "Good to Firm"
        case .firm: return "Firm"
        case .slow: return "Slow"
        case .standardToSlow: return "Standard to Slow"
        case .standard: return "Standard"
        case .standardToFast: return "Standard to Fast"
        case .fast: return "Fast"
        case .unknown: return "Unknown"
        }
    }

    /// Ordinal on a soft→firm scale, for comparing a horse's past going to today's.
    /// `nil` for `.unknown`. Turf and all-weather share the scale by feel, which is
    /// rough but only ever used to compare like with like within a surface.
    public var firmnessRank: Int? {
        switch self {
        case .heavy, .slow: return 0
        case .soft, .standardToSlow: return 1
        case .goodToSoft: return 2
        case .good, .standard: return 3
        case .goodToFirm, .standardToFast: return 4
        case .firm, .fast: return 5
        case .unknown: return nil
        }
    }
}

public enum Surface: String, Codable, Sendable, CaseIterable {
    case turf
    case allWeather
    case unknown

    public init(raw: String?) {
        guard let raw else { self = .unknown; return }
        switch raw.lowercased().replacingOccurrences(of: " ", with: "") {
        case "turf", "grass": self = .turf
        case "aw", "allweather", "polytrack", "tapeta", "fibresand", "dirt", "sand":
            self = .allWeather
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .turf: return "Turf"
        case .allWeather: return "All-Weather"
        case .unknown: return "Unknown"
        }
    }
}

/// Code of racing. Matters to the rating engine: completion rate is meaningful
/// over jumps and close to meaningless on the Flat, and the draw only applies on
/// the Flat.
public enum RaceType: String, Codable, Sendable, CaseIterable {
    case flat
    case hurdle
    case chase
    case nationalHuntFlat
    case unknown

    public init(raw: String?) {
        guard let raw else { self = .unknown; return }
        let key = raw.lowercased().replacingOccurrences(of: " ", with: "")
        switch key {
        case "flat": self = .flat
        case "hurdle", "hurdles": self = .hurdle
        case "chase", "chases", "steeplechase": self = .chase
        case "nhflat", "nationalhuntflat", "bumper", "inhflat": self = .nationalHuntFlat
        default: self = .unknown
        }
    }

    /// Whether runners jump obstacles — so whether a non-completion in the form
    /// string carries the weight it does over fences.
    public var isJumps: Bool {
        self == .hurdle || self == .chase
    }

    public var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .hurdle: return "Hurdle"
        case .chase: return "Chase"
        case .nationalHuntFlat: return "NH Flat"
        case .unknown: return "Unknown"
        }
    }
}

/// A race distance, held in furlongs because that is what the provider gives and
/// what comparisons want. Display converts to the miles-and-furlongs form that
/// every British racecard uses.
public struct Distance: Codable, Hashable, Sendable, Comparable {
    public let furlongs: Double

    public init?(furlongs: Double?) {
        guard let furlongs, furlongs > 0, furlongs.isFinite else { return nil }
        self.furlongs = furlongs
    }

    public init(exactFurlongs: Double) {
        self.furlongs = exactFurlongs
    }

    /// "5f", "1m", "1m 2f", "2m 4½f" — the form a racecard prints.
    public var displayString: String {
        let totalEighths = Int((furlongs * 2).rounded())
        let wholeFurlongs = totalEighths / 2
        let hasHalf = totalEighths % 2 == 1
        let miles = wholeFurlongs / 8
        let remainder = wholeFurlongs % 8

        var parts: [String] = []
        if miles > 0 { parts.append("\(miles)m") }
        if remainder > 0 || hasHalf {
            parts.append("\(remainder > 0 ? String(remainder) : "")\(hasHalf ? "½" : "")f")
        }
        return parts.isEmpty ? "\(furlongs)f" : parts.joined(separator: " ")
    }

    /// Sprint distances are where the draw matters most on the Flat.
    public var isSprint: Bool { furlongs <= 6 }

    public static func < (lhs: Distance, rhs: Distance) -> Bool {
        lhs.furlongs < rhs.furlongs
    }
}
