import XCTest
@testable import RacesKit

/// Naming the field that could not be read.
///
/// This suite exists because of a diagnostic that was a real improvement and
/// still not enough. `Test Betfair` reported:
///
///     We couldn't read the reply — HTTP 200, application/json, 418321 bytes:
///     [{"marketId":"1.262709800","marketName":"1m2f Mdn Stks",…
///
/// Every fact there says the response is fine, and it was: a valid catalogue of
/// a full Wednesday card. One value some way down it was not the type we
/// expected, and nothing in the message could say so — not the status, not the
/// content type, not 160 characters of a 418KB body. The coding path is the one
/// fact that identifies it, and Foundation had it all along.
final class DecodingFailureTests: XCTestCase {

    // MARK: - Rendering a path

    func test_arrayIndicesAreBracketedAndKeysAreDotted() {
        let path = DecodingFailure.describe([
            Key(index: 0), Key("runners"), Key(index: 3), Key("metadata"), Key("SIRE_NAME"),
        ] as [any CodingKey])

        // Readable as a path someone can follow into the payload by hand, which
        // is the entire job.
        XCTAssertEqual(path, "[0].runners[3].metadata.SIRE_NAME")
    }

    func test_aLeadingKeyGetsNoStrayDot() {
        XCTAssertEqual(DecodingFailure.describe([Key("marketId")] as [any CodingKey]), "marketId")
    }

    func test_anEmptyPathSaysSoRatherThanRenderingBlank() {
        // Not padding: a type mismatch at the root is what an HTML error page
        // decodes to, and "" in the middle of a sentence reads as a bug.
        XCTAssertEqual(DecodingFailure.describe([] as [any CodingKey]), "(the whole response)")
    }

    // MARK: - From a real decode

    func test_aNullWhereAValueIsRequiredNamesTheFieldAndTheRunner() throws {
        // The shape of the reported failure, reproduced through the real
        // decoder rather than by constructing a DecodingError by hand.
        let json = Data(#"""
        [{"marketId":"1.262709800","runners":[
            {"selectionId":102146666},
            {"selectionId":null}
        ]}]
        """#.utf8)

        let failure = try XCTUnwrap(
            decodingFailure(of: [BetfairMarketCatalogue].self, from: json))

        XCTAssertEqual(failure.path, "[0].runners[1].selectionId")
        XCTAssertFalse(failure.reason.isEmpty)
    }

    func test_aMissingKeyIsNamedEvenThoughItIsNotInTheContainersPath() throws {
        // `keyNotFound` puts the container in `codingPath` and the absent key
        // beside it, so taking the path alone drops the only useful part.
        let json = Data(#"[{"marketName":"1m2f Mdn Stks"}]"#.utf8)

        let failure = try XCTUnwrap(
            decodingFailure(of: [BetfairMarketCatalogue].self, from: json))

        XCTAssertEqual(failure.path, "[0].marketId")
    }

    func test_aWrongTypeAtTheTopLevelIsReportedAtTheRoot() throws {
        let json = Data(#"{"loginRequired":true}"#.utf8)

        let failure = try XCTUnwrap(
            decodingFailure(of: [BetfairMarketCatalogue].self, from: json))

        XCTAssertEqual(failure.path, "(the whole response)")
    }

    func test_bodyThatIsNotJSONAtAllStillProducesAFailure() throws {
        let failure = try XCTUnwrap(
            decodingFailure(of: [BetfairMarketCatalogue].self, from: Data("<html>".utf8)))

        XCTAssertEqual(failure.path, "(the whole response)")
        XCTAssertFalse(failure.reason.isEmpty)
    }

    func test_somethingThatIsNotADecodingErrorHasNoPayload() {
        // So a caller can offer every error it catches and get a payload only
        // where there is one, rather than testing the type at the call site.
        XCTAssertNil(DecodingFailure(APIError.timedOut))
    }

    // MARK: - The reason is safe to paste

    func test_theReasonIsOneLine() {
        let reason = DecodingFailure.tidy(
            "Expected to decode String\n  but found null\n  instead.", fallback: "x")

        XCTAssertFalse(reason.contains("\n"))
        XCTAssertEqual(reason, "Expected to decode String but found null instead.")
    }

    func test_theReasonIsRedactedLikeABodySnippet() {
        // `dataCorrupted` occasionally quotes the offending value, and this
        // string is built to be pasted into an issue unread.
        let reason = DecodingFailure.tidy(
            "Parsed value ABCDEFGHIJKLMNOPQRSTUVWXYZ0123 is out of range", fallback: "x")

        XCTAssertFalse(reason.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"), reason)
        XCTAssertTrue(reason.contains("out of range"), reason)
    }

    func test_aLongReasonIsTruncated() {
        let reason = DecodingFailure.tidy(
            String(repeating: "ab ", count: 200), fallback: "x")

        XCTAssertTrue(reason.hasSuffix("…"), reason)
        XCTAssertLessThanOrEqual(reason.count, DecodingFailure.reasonLimit + 1)
    }

    func test_anEmptyReasonFallsBackToTheKindOfFailure() {
        XCTAssertEqual(DecodingFailure.tidy("   ", fallback: "wrong type"), "wrong type")
    }

    // MARK: - On the message the user reads

    func test_theShapeLeadsWithThePathAndStillShowsTheBody() {
        let shape = HTTPResponseShape(
            statusCode: 200,
            contentType: "application/json",
            body: Data(#"[{"marketId":"1.262709800"}]"#.utf8),
            failure: DecodingFailure(
                path: "[0].runners[3].metadata.SIRE_NAME",
                reason: "Expected String value but found null instead."))

        let description = shape.description
        XCTAssertTrue(description.contains("HTTP 200"), description)
        XCTAssertTrue(description.contains("application/json"), description)
        XCTAssertTrue(description.contains("[0].runners[3].metadata.SIRE_NAME"), description)
        // The body still earns its place: it is what separates a card with one
        // odd runner from a login page.
        XCTAssertTrue(description.contains("1.262709800"), description)
    }

    func test_aShapeWithNoFailureReadsExactlyAsItDidBefore() {
        let shape = HTTPResponseShape(
            statusCode: 503, contentType: "text/html", body: Data("<html>".utf8))

        XCTAssertNil(shape.failure)
        XCTAssertEqual(shape.description, "HTTP 503, text/html, 6 bytes: <html>")
    }

    // MARK: - Helpers

    private func decodingFailure<T: Decodable>(
        of type: T.Type,
        from data: Data
    ) -> DecodingFailure? {
        do {
            _ = try JSONDecoder().decode(type, from: data)
            XCTFail("expected the decode to fail")
            return nil
        } catch {
            return DecodingFailure(error)
        }
    }

    /// A stand-in `CodingKey`, since the real ones are private to the decoder.
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(_ stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init(index: Int) {
            self.stringValue = "Index \(index)"
            self.intValue = index
        }

        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { self.init(index: intValue) }
    }
}
