import Foundation

/// How a horse finished — or failed to.
///
/// The provider sends this as a string, and a good proportion of the time it is
/// not a number at all. Over jumps, "PU" and "F" are routine. Settling a tip needs
/// to tell "beaten into fourth" from "never completed", so the distinction is
/// modelled rather than coerced to an Int.
public enum FinishPosition: Codable, Hashable, Sendable {
    case finished(Int)
    case pulledUp
    case unseatedRider
    case fell
    case refused
    case broughtDown
    case slippedUp
    case disqualified
    case voided
    /// Something we have not seen before, kept verbatim so it can be inspected
    /// rather than silently swallowed.
    case other(String)

    public init(raw: String?) {
        guard let raw else { self = .other(""); return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if let position = Int(key), position > 0 {
            self = .finished(position)
            return
        }
        switch key {
        case "PU", "P": self = .pulledUp
        case "UR", "U": self = .unseatedRider
        case "F": self = .fell
        case "REF", "R": self = .refused
        case "BD", "B": self = .broughtDown
        case "SU", "S": self = .slippedUp
        case "DSQ", "DQ", "D": self = .disqualified
        case "VOI", "V": self = .voided
        default: self = .other(key)
        }
    }

    public var isWinner: Bool {
        if case .finished(1) = self { return true }
        return false
    }

    public var didComplete: Bool {
        if case .finished = self { return true }
        return false
    }

    /// The finishing position, or nil if the horse did not complete.
    public var numericPosition: Int? {
        if case .finished(let position) = self { return position }
        return nil
    }

    public var displayString: String {
        switch self {
        case .finished(let position): return String(position)
        case .pulledUp: return "PU"
        case .unseatedRider: return "UR"
        case .fell: return "F"
        case .refused: return "REF"
        case .broughtDown: return "BD"
        case .slippedUp: return "SU"
        case .disqualified: return "DSQ"
        case .voided: return "VOI"
        case .other(let raw): return raw
        }
    }
}

/// One horse's outcome in a settled race.
public struct Finisher: Codable, Hashable, Sendable {
    public let horseID: String
    public let horseName: String
    public let position: FinishPosition
    public let clothNumber: Int?
    public let draw: Int?
    public let weightPounds: Int?
    public let officialRating: Int?
    public let jockeyID: String?
    public let trainerID: String?
    /// Starting price as a decimal. Paid tiers only — the free results endpoint
    /// carries no price at all, which is why ROI comes from Betfair SP instead.
    public let startingPriceDecimal: Double?

    public init(
        horseID: String,
        horseName: String,
        position: FinishPosition,
        clothNumber: Int? = nil,
        draw: Int? = nil,
        weightPounds: Int? = nil,
        officialRating: Int? = nil,
        jockeyID: String? = nil,
        trainerID: String? = nil,
        startingPriceDecimal: Double? = nil
    ) {
        self.horseID = horseID
        self.horseName = horseName
        self.position = position
        self.clothNumber = clothNumber
        self.draw = draw
        self.weightPounds = weightPounds
        self.officialRating = officialRating
        self.jockeyID = jockeyID
        self.trainerID = trainerID
        self.startingPriceDecimal = startingPriceDecimal
    }
}

/// A settled race. The archive is built from these, and tips are reconciled
/// against them.
public struct RaceResult: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let courseName: String
    public let name: String
    public let date: String
    public let offDateTime: Date?
    public let distance: Distance?
    public let going: Going
    public let surface: Surface
    public let type: RaceType
    public let raceClass: Int?
    public let finishers: [Finisher]

    public init(
        id: String,
        courseName: String,
        name: String,
        date: String,
        offDateTime: Date? = nil,
        distance: Distance? = nil,
        going: Going = .unknown,
        surface: Surface = .unknown,
        type: RaceType = .unknown,
        raceClass: Int? = nil,
        finishers: [Finisher] = []
    ) {
        self.id = id
        self.courseName = courseName
        self.name = name
        self.date = date
        self.offDateTime = offDateTime
        self.distance = distance
        self.going = going
        self.surface = surface
        self.type = type
        self.raceClass = raceClass
        self.finishers = finishers
    }

    public var winner: Finisher? {
        finishers.first { $0.position.isWinner }
    }

    public func finisher(horseID: String) -> Finisher? {
        finishers.first { $0.horseID == horseID }
    }

    /// Whether a horse ran at all. Absence from a settled result means it was
    /// withdrawn — a void bet, not a losing one, and the accuracy tracker depends
    /// on getting that distinction right.
    ///
    /// Guarded on field size: a truncated payload would otherwise settle every
    /// runner as a non-runner and quietly wipe a day's tips.
    public func didRun(horseID: String) -> Bool? {
        guard finishers.count >= 3 else { return nil }
        return finisher(horseID: horseID) != nil
    }
}
