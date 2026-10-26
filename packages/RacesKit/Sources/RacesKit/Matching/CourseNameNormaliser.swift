import Foundation

/// Reduces a racecourse name to a comparison key.
///
/// The two providers name the same course differently and neither is wrong:
/// the Racing API says `Catterick Bridge`, `Great Yarmouth`, `Epsom Downs`;
/// Betfair's `Event.venue` says `Catterick`, `Yarmouth`, `Epsom`. Comparing the
/// raw strings would match almost nothing.
///
/// The rule this follows is: **normalise only what is decoration.** Every word
/// removed here is one that no British or Irish course needs in order to be
/// identified, and `CourseNameNormaliserTests` asserts that the full list of GB
/// and Irish courses still produces distinct keys. That test is the safety net —
/// a normaliser that collapses two real courses together would silently price one
/// meeting's races off another's market, which is far worse than not matching.
public enum CourseNameNormaliser {

    /// Words that are never load-bearing at the end of a course name.
    ///
    /// `Kempton Park` / `Kempton`, `Epsom Downs` / `Epsom`,
    /// `Catterick Bridge` / `Catterick`, `Chelmsford City` / `Chelmsford`.
    /// Only stripped as whole trailing words, so `Newton Abbot` and
    /// `Market Rasen` keep the part that identifies them.
    private static let droppableSuffixes: Set<String> = [
        "park", "downs", "bridge", "city", "racecourse", "racetrack", "races",
    ]

    /// Likewise at the front. `The Curragh` / `Curragh`,
    /// `Great Yarmouth` / `Yarmouth`.
    ///
    /// Deliberately **not** including `royal`: `Down Royal` is a course in its own
    /// right, and dropping the word would leave `down`.
    private static let droppablePrefixes: Set<String> = [
        "the", "great",
    ]

    /// The comparison key. Lowercased words joined by single spaces.
    public static func key(_ raw: String) -> String {
        var text = raw.lowercased()

        // `Newmarket (July)`, `Dundalk (AW)`, `Wolverhampton (Tapeta)`.
        //
        // Note what this throws away: Newmarket's July Course and Rowley Mile are
        // genuinely different tracks, and after this they share a key. That is
        // correct for matching, because Betfair calls both of them `Newmarket` —
        // the two meetings are told apart by start time and by which horses are
        // in them, not by name.
        text = stripParentheticals(from: text)

        // `Bangor-on-Dee` → `bangor`, `Stratford-on-Avon` → `stratford`.
        // Hyphens first so the `on` is a word we can see.
        text = text.replacingOccurrences(of: "-", with: " ")

        var words = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        if let onIndex = words.firstIndex(of: "on"), onIndex > 0 {
            words = Array(words[..<onIndex])
        }

        while let first = words.first, droppablePrefixes.contains(first), words.count > 1 {
            words.removeFirst()
        }

        while let last = words.last, droppableSuffixes.contains(last), words.count > 1 {
            words.removeLast()
        }

        return words.joined(separator: " ")
    }

    /// True when two names describe the same course.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = key(lhs)
        guard !left.isEmpty else { return false }
        return left == key(rhs)
    }

    private static func stripParentheticals(from text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "[":
                depth += 1
            case ")", "]":
                depth = max(0, depth - 1)
            default:
                if depth == 0 { result.append(character) }
            }
        }
        return result
    }
}
