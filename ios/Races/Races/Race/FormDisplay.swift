import Foundation
import RacesKit

/// How a form string is shown to the user.
///
/// The provider sends it oldest-first, which is the convention a racecard prints
/// and which nobody unfamiliar with racing reads correctly: in `1-3241` the last
/// run is the `1` on the **right**. Displaying it raw next to a "most recent"
/// label would be actively misleading, so anywhere this app puts form beside a
/// chronological claim it reverses the string and says which end is which.
nonisolated enum FormDisplay {

    /// The raw string reversed, so the leftmost character is the latest run.
    /// Season and gap markers are kept — they carry meaning — and simply move.
    static func mostRecentFirst(_ raw: String) -> String {
        String(raw.reversed())
    }

    static func describe(_ outcome: FormOutcome) -> String {
        switch outcome {
        case .finished(let position) where position >= 10:
            return "Tenth or worse"
        case .finished(1): return "Won"
        case .finished(2): return "Second"
        case .finished(3): return "Third"
        case .finished(let position): return "\(position)th"
        case .pulledUp: return "Pulled up"
        case .unseatedRider: return "Unseated rider"
        case .fell: return "Fell"
        case .refused: return "Refused"
        case .broughtDown: return "Brought down"
        case .slippedUp: return "Slipped up"
        case .disqualified: return "Disqualified"
        case .voided: return "Void"
        case .seasonBreak: return "New season"
        case .longBreak: return "Long break"
        case .unrecognised(let character): return "Unknown (\(character))"
        }
    }
}
