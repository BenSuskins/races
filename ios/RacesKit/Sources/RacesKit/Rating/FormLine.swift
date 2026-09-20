import Foundation

/// One entry in a horse's form string.
public enum FormOutcome: Hashable, Sendable {
    /// A finishing position as printed. `0` in a form string means tenth or worse,
    /// and is represented here as `.finished(10)` — the exact position is unknown
    /// but "well beaten" is the information that matters.
    case finished(Int)
    case pulledUp
    case unseatedRider
    case fell
    case refused
    case broughtDown
    case slippedUp
    case disqualified
    case voided
    /// Separates racing seasons.
    case seasonBreak
    /// A longer gap, typically a missed season.
    case longBreak
    case unrecognised(Character)

    /// Whether the horse completed the course.
    public var didComplete: Bool {
        if case .finished = self { return true }
        return false
    }

    /// Whether this is a run at all, as opposed to a gap marker.
    public var isRun: Bool {
        switch self {
        case .seasonBreak, .longBreak, .unrecognised: return false
        default: return true
        }
    }

    public var isWin: Bool {
        if case .finished(1) = self { return true }
        return false
    }
}

/// A parsed form string.
///
/// **Ordering matters and is easy to get backwards.** UK convention puts the most
/// recent run on the **right**: `1-3241` means the last run was a win. Reversing
/// that would silently invert the strongest form signal available on the free tier,
/// and nothing else about the output would look wrong — so `outcomes` is documented
/// as oldest-first and there are tests pinning it.
public struct FormLine: Hashable, Sendable {
    public let raw: String
    /// Oldest first, matching the source string. The last element is the most
    /// recent run.
    public let outcomes: [FormOutcome]

    public init(raw: String, outcomes: [FormOutcome]) {
        self.raw = raw
        self.outcomes = outcomes
    }

    /// Actual runs, oldest first, with gap markers removed.
    public var runs: [FormOutcome] {
        outcomes.filter(\.isRun)
    }

    public var runCount: Int { runs.count }

    public var isEmpty: Bool { runCount == 0 }

    /// The most recent run, or nil for a horse that has never run.
    public var lastRun: FormOutcome? { runs.last }

    public var wonLastTime: Bool? {
        guard let lastRun else { return nil }
        return lastRun.isWin
    }

    /// Completed runs as a share of all runs. Meaningful over jumps, close to
    /// meaningless on the Flat where almost everything completes.
    public var completionRate: Double? {
        guard runCount > 0 else { return nil }
        return Double(runs.filter(\.didComplete).count) / Double(runCount)
    }

    /// Whether there is a long break anywhere in the string — a horse returning
    /// from a year off is a different proposition from one in mid-campaign.
    public var hasLongBreak: Bool {
        outcomes.contains { $0 == .longBreak }
    }
}

/// Parses form strings.
///
/// Deliberately total: it never throws, never rejects a string, and turns anything
/// unrecognised into `.unrecognised` rather than failing. A novel character in one
/// horse's form must not cost us the racecard.
public enum FormParser {

    public static func parse(_ raw: String?) -> FormLine {
        guard let raw else { return FormLine(raw: "", outcomes: []) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return FormLine(raw: "", outcomes: []) }

        let outcomes = trimmed.compactMap(outcome(for:))
        return FormLine(raw: trimmed, outcomes: outcomes)
    }

    static func outcome(for character: Character) -> FormOutcome? {
        if let digit = character.wholeNumberValue, (0...9).contains(digit) {
            // '0' means tenth or worse, not "position zero".
            return .finished(digit == 0 ? 10 : digit)
        }

        switch character.uppercased() {
        case "-": return .seasonBreak
        case "/": return .longBreak
        case "P": return .pulledUp
        case "U": return .unseatedRider
        case "F": return .fell
        case "R": return .refused
        case "B": return .broughtDown
        case "S": return .slippedUp
        case "D": return .disqualified
        case "V": return .voided
        case " ", ",": return nil
        default: return .unrecognised(character)
        }
    }
}
