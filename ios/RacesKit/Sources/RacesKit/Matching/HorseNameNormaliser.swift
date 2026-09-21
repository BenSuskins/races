import Foundation

/// Reduces a horse name to a comparison key, and measures how far apart two
/// names are when the keys differ.
///
/// Betfair decorates runner names in two ways the Racing API does not:
/// a cloth-number prefix (`3. Kyprios`) and a country-of-breeding suffix
/// (`Kyprios (IRE)`). Both are display conventions rather than part of the name,
/// so both come off before anything is compared.
public enum HorseNameNormaliser {

    /// The comparison key: uppercase letters and digits only.
    ///
    /// Punctuation goes because the two providers disagree about it — apostrophes
    /// in particular arrive as `'`, `’` or not at all.
    public static func key(_ raw: String) -> String {
        var text = raw

        text = stripClothPrefix(from: text)
        text = stripCountrySuffix(from: text)

        return String(text.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    /// `3. Kyprios` → `Kyprios`. Also handles `3) Kyprios` and `3 Kyprios`.
    ///
    /// Only a *leading* run of digits followed by a separator, so a name that
    /// genuinely starts with a number keeps it.
    private static func stripClothPrefix(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var index = trimmed.startIndex
        var sawDigit = false

        while index < trimmed.endIndex, trimmed[index].isNumber {
            sawDigit = true
            index = trimmed.index(after: index)
        }
        guard sawDigit, index < trimmed.endIndex else { return trimmed }

        // The separator is what tells a cloth prefix from a name starting with a
        // numeral. Without one, leave it alone.
        if trimmed[index] == "." || trimmed[index] == ")" {
            index = trimmed.index(after: index)
        } else if !trimmed[index].isWhitespace {
            return trimmed
        }

        let remainder = trimmed[index...].trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? trimmed : remainder
    }

    /// `Kyprios (IRE)` → `Kyprios`.
    ///
    /// Only a trailing parenthetical of two to three letters, which is the shape
    /// of every country code. Anything longer is left in place rather than
    /// guessed at.
    private static func stripCountrySuffix(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            return trimmed
        }

        let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        guard (2...3).contains(inside.count), inside.allSatisfy(\.isLetter) else {
            return trimmed
        }

        let remainder = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? trimmed : remainder
    }

    /// Levenshtein distance, stopping early once the answer cannot be within
    /// `limit`.
    ///
    /// Used only as a last resort, and only for a typo-sized gap: two horses in
    /// the same race can have genuinely similar names, so a generous threshold
    /// here buys mismatches rather than matches.
    public static func distance(_ lhs: String, _ rhs: String, limit: Int) -> Int? {
        let left = Array(lhs)
        let right = Array(rhs)

        if left == right { return 0 }
        if abs(left.count - right.count) > limit { return nil }
        if left.isEmpty { return right.count <= limit ? right.count : nil }
        if right.isEmpty { return left.count <= limit ? left.count : nil }

        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            var rowBest = current[0]

            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                rowBest = min(rowBest, current[j])
            }

            // Every remaining row can only grow this minimum, so if the whole row
            // is already past the limit the answer is too.
            if rowBest > limit { return nil }
            swap(&previous, &current)
        }

        let result = previous[right.count]
        return result <= limit ? result : nil
    }
}
