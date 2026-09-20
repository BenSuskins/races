import Foundation

/// A number the provider might send in any of several shapes.
///
/// The Racing API is inconsistent about this: the same field can arrive as a JSON
/// number (`7`), a numeric string (`"7.0"`), an empty string, or a placeholder
/// like `"-"` when the value is simply not known — an unraced two-year-old has no
/// official rating, and a jumps runner has no draw.
///
/// Decoding those strictly would throw and lose the whole racecard. Decoding them
/// as "zero" would be worse: a horse with *no* official rating would rate as the
/// worst in the field rather than as unknown, and the rating engine treats those
/// two cases very differently. So this resolves to `nil`, which every factor
/// reads as race-neutral.
public struct LenientNumber: Codable, Hashable, Sendable {
    public let double: Double?

    public var int: Int? {
        guard let double, double.isFinite else { return nil }
        return Int(double.rounded())
    }

    public init(_ double: Double?) {
        self.double = double
    }

    /// Values that mean "not applicable" rather than a quantity. Includes both
    /// hyphen-minus and the en/em dashes that turn up in scraped-looking fields.
    private static let placeholders: Set<String> = [
        "-", "–", "—", "n/a", "na", "null", "nil", "nr", "?",
    ]

    static func parse(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !placeholders.contains(trimmed.lowercased()) else { return nil }
        return Double(trimmed)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.double = nil
        } else if let value = try? container.decode(Double.self) {
            self.double = value
        } else if let value = try? container.decode(Int.self) {
            self.double = Double(value)
        } else if let value = try? container.decode(String.self) {
            self.double = Self.parse(value)
        } else {
            // A shape we have never seen — a nested object, say. Treat it as
            // unknown rather than failing the whole payload.
            self.double = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let double {
            try container.encode(double)
        } else {
            try container.encodeNil()
        }
    }
}

/// A string the provider might send as a number.
///
/// The mirror image of `LenientNumber`, and learned the hard way: `position` is
/// declared as a string, holds `"PU"` and `"F"` over jumps, and also arrives as a
/// bare JSON `1`. Any field that is nominally text but sometimes numeric needs
/// this, or one unquoted value throws away the whole race.
public struct LenientText: Codable, Hashable, Sendable {
    public let value: String?

    public init(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.init(nil)
        } else if let text = try? container.decode(String.self) {
            self.init(text)
        } else if let int = try? container.decode(Int.self) {
            self.init(String(int))
        } else if let double = try? container.decode(Double.self) {
            // Render 3.0 as "3": these are positions and classes, not measurements.
            self.init(double == double.rounded() ? String(Int(double)) : String(double))
        } else {
            self.init(nil)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }
}
