import XCTest
@testable import RacesKit

private struct Holder: Codable, Equatable {
    let value: LenientNumber?
}

final class LenientNumberTests: XCTestCase {

    private func decode(_ json: String) throws -> LenientNumber? {
        try JSONDecoder().decode(Holder.self, from: Data(json.utf8)).value
    }

    // MARK: - Shapes the provider actually sends

    func test_decodesJSONNumbers() throws {
        XCTAssertEqual(try decode(#"{"value": 95}"#)?.int, 95)
        XCTAssertEqual(try decode(#"{"value": 8.5}"#)?.double, 8.5)
        XCTAssertEqual(try decode(#"{"value": -3}"#)?.int, -3)
    }

    /// The Racing API's own OpenAPI spec declares `ofr`, `lbs`, `draw`, `number`
    /// and `last_run` as `type: string`, so quoted numbers are the normal case
    /// rather than an oddity.
    func test_decodesNumericStrings() throws {
        XCTAssertEqual(try decode(#"{"value": "95"}"#)?.int, 95)
        XCTAssertEqual(try decode(#"{"value": "8.0"}"#)?.double, 8.0)
        XCTAssertEqual(try decode(#"{"value": " 133 "}"#)?.int, 133)
    }

    // MARK: - Shapes that mean "unknown"

    /// This is the case that matters most. A horse with no official rating must
    /// come out as unknown, not as zero — zero would rate it the worst in the
    /// field, which is a confident, wrong, and invisible claim about every
    /// first-time runner.
    func test_unknownValuesBecomeNilNotZero() throws {
        for json in [
            #"{"value": null}"#,
            #"{"value": ""}"#,
            #"{"value": "   "}"#,
            #"{"value": "-"}"#,
            #"{"value": "–"}"#,
            #"{"value": "N/A"}"#,
            #"{"value": "n/a"}"#,
            #"{"value": "NR"}"#,
            #"{"value": "?"}"#,
        ] {
            let decoded = try decode(json)
            XCTAssertNil(decoded?.double, "\(json) should decode as unknown")
            XCTAssertNotEqual(decoded?.double, 0, "\(json) must never become zero")
        }
    }

    func test_missingKeyIsUnknown() throws {
        XCTAssertNil(try decode(#"{}"#))
    }

    func test_unparseableStringIsUnknown() throws {
        XCTAssertNil(try decode(#"{"value": "not a number"}"#)?.double)
    }

    /// A shape we have never seen should cost us one field, not the whole payload.
    func test_unexpectedShapeDoesNotThrow() throws {
        XCTAssertNil(try decode(#"{"value": {"nested": 1}}"#)?.double)
        XCTAssertNil(try decode(#"{"value": [1, 2]}"#)?.double)
        XCTAssertNil(try decode(#"{"value": true}"#)?.double)
    }

    // MARK: - Conversion

    func test_intRounds() {
        XCTAssertEqual(LenientNumber(8.4).int, 8)
        XCTAssertEqual(LenientNumber(8.5).int, 9)
        XCTAssertEqual(LenientNumber(-8.5).int, -9)
    }

    func test_intOfNonFiniteIsNil() {
        XCTAssertNil(LenientNumber(.nan).int)
        XCTAssertNil(LenientNumber(.infinity).int)
        XCTAssertNil(LenientNumber(nil).int)
    }

    // MARK: - Round trip

    func test_roundTrips() throws {
        let original = Holder(value: LenientNumber(95))
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Holder.self, from: data), original)
    }

    /// An unknown value survives a round trip *as unknown*, which is what the app
    /// cares about. It does not survive as the same Optional nesting: encoding
    /// `.some(LenientNumber(nil))` writes `null`, and `null` decodes back to
    /// `.none`. Both mean "we do not know this", every reader treats them
    /// identically, and asserting on the nesting instead of the meaning would be
    /// testing an implementation detail nothing depends on.
    func test_unknownRoundTripsAsUnknown() throws {
        let unknown = Holder(value: LenientNumber(nil))
        let data = try JSONEncoder().encode(unknown)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"value":null}"#)

        let decoded = try JSONDecoder().decode(Holder.self, from: data)
        XCTAssertNil(decoded.value?.double)
        XCTAssertNil(decoded.value?.int)
    }
}

final class LenientTextTests: XCTestCase {

    private struct TextHolder: Codable, Equatable {
        let value: LenientText?
    }

    private func decode(_ json: String) throws -> LenientText? {
        try JSONDecoder().decode(TextHolder.self, from: Data(json.utf8)).value
    }

    func test_decodesStrings() throws {
        XCTAssertEqual(try decode(#"{"value": "PU"}"#)?.value, "PU")
        XCTAssertEqual(try decode(#"{"value": "  1  "}"#)?.value, "1")
    }

    /// The failure that prompted this type: `position` is declared a string, holds
    /// "PU" over jumps, and also arrives as a bare JSON number. One unquoted value
    /// was throwing away the whole race.
    func test_decodesNumbersAsText() throws {
        XCTAssertEqual(try decode(#"{"value": 3}"#)?.value, "3")
        XCTAssertEqual(try decode(#"{"value": 3.0}"#)?.value, "3")
        XCTAssertEqual(try decode(#"{"value": 3.5}"#)?.value, "3.5")
    }

    func test_blanksAndNullsAreUnknown() throws {
        XCTAssertNil(try decode(#"{"value": null}"#)?.value)
        XCTAssertNil(try decode(#"{"value": ""}"#)?.value)
        XCTAssertNil(try decode(#"{"value": "   "}"#)?.value)
        XCTAssertNil(try decode(#"{}"#))
    }

    func test_unexpectedShapeDoesNotThrow() throws {
        XCTAssertNil(try decode(#"{"value": {"a": 1}}"#)?.value)
        XCTAssertNil(try decode(#"{"value": [1]}"#)?.value)
    }
}
