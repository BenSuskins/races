import XCTest
@testable import RacesKit

/// What the app says when Betfair answers with something that is not a login
/// reply.
///
/// This suite exists because of a real dead end. The Settings screen reported
/// "We received an unexpected response. Please try again." — `APIError.decoding`
/// — for a login that had never been checked at all. Trying again could not
/// help, re-typing the password could not help, and the message named neither
/// the status, the content type, nor anything about the body. The one question
/// the Betfair provider was built to answer became unanswerable from the device
/// it was failing on.
final class BetfairLoginDiagnosticTests: XCTestCase {

    private let credentials = BetfairCredentials(
        appKey: "APPKEY", username: "ben", password: "pa+ssword")

    private func makeSession(_ transport: FakeHTTPTransport) -> BetfairSession {
        BetfairSession(
            credentials: credentials,
            transport: transport,
            requestsPerSecond: 1000,
            now: { Date(timeIntervalSince1970: 1_000_000) })
    }

    // MARK: - The shape of an unreadable body

    func test_anEmptyBodyIsSaidToBeEmptyRatherThanQuotedAsNothing() {
        let shape = HTTPResponseShape(
            statusCode: 200, contentType: "application/json", body: Data())

        XCTAssertEqual(shape.snippet, "(empty body)")
        XCTAssertEqual(shape.byteCount, 0)
    }

    func test_theContentTypeLosesItsParameters() {
        // `text/html; charset=utf-8` and `text/html` are the same finding, and
        // the charset is noise in a one-line message.
        let shape = HTTPResponseShape(
            statusCode: 200,
            contentType: "text/HTML; charset=utf-8",
            body: Data("<html></html>".utf8))

        XCTAssertEqual(shape.contentType, "text/html")
    }

    func test_aMissingContentTypeIsNotInventedOrLeftBlank() {
        let shape = HTTPResponseShape(statusCode: 200, contentType: nil, body: Data("x".utf8))

        XCTAssertNil(shape.contentType)
        XCTAssertTrue(shape.description.contains("no content type"), shape.description)
    }

    func test_anEmptyContentTypeHeaderCountsAsMissing() {
        let shape = HTTPResponseShape(statusCode: 200, contentType: "  ", body: Data("x".utf8))

        XCTAssertNil(shape.contentType)
    }

    func test_whitespaceAndNewlinesAreCollapsedSoTheSnippetIsOneLine() {
        let shape = HTTPResponseShape(
            statusCode: 200,
            contentType: "text/html",
            body: Data("<html>\n  <body>\n    Hello\n  </body>\n</html>".utf8))

        XCTAssertEqual(shape.snippet, "<html> <body> Hello </body> </html>")
    }

    func test_aLongBodyIsTruncatedRatherThanDumpedIntoTheUI() {
        let body = String(repeating: "ab ", count: 400)
        let shape = HTTPResponseShape(
            statusCode: 200, contentType: "text/html", body: Data(body.utf8))

        XCTAssertTrue(shape.snippet.hasSuffix("…"), shape.snippet)
        XCTAssertLessThanOrEqual(shape.snippet.count, HTTPResponseShape.snippetLimit + 1)
        // The real length is still reported, because "how big was it" separates
        // an error page from a truncated reply.
        XCTAssertEqual(shape.byteCount, body.utf8.count)
    }

    func test_longAlphanumericRunsAreRedacted() {
        // The point is that a diagnostic can be pasted into an issue without
        // anyone having to read it first. Tokens, ids and hashes go.
        let shape = HTTPResponseShape(
            statusCode: 200,
            contentType: "text/plain",
            body: Data("session ABCDEFGHIJKLMNOPQRSTUVWXYZ0123 ended".utf8))

        XCTAssertFalse(shape.snippet.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"), shape.snippet)
        XCTAssertTrue(shape.snippet.contains("…"), shape.snippet)
        // Short words are prose and stay, or the snippet identifies nothing.
        XCTAssertTrue(shape.snippet.contains("session"), shape.snippet)
        XCTAssertTrue(shape.snippet.contains("ended"), shape.snippet)
    }

    func test_htmlIsRecognisedFromTheContentTypeAndFromTheBody() {
        let byHeader = HTTPResponseShape(
            statusCode: 200, contentType: "text/html", body: Data("nothing".utf8))
        let byBody = HTTPResponseShape(
            statusCode: 200, contentType: nil, body: Data("<!DOCTYPE html><html>".utf8))
        let json = HTTPResponseShape(
            statusCode: 200, contentType: "application/json", body: Data("[]".utf8))

        XCTAssertTrue(byHeader.looksLikeHTML)
        XCTAssertTrue(byBody.looksLikeHTML)
        XCTAssertFalse(json.looksLikeHTML)
    }

    // MARK: - Through a login

    func test_anHTMLPageIsReportedAsAnUnreadableReplyRatherThanADecodingError() async {
        // The reported failure. A 200 carrying a web page — what a jurisdiction
        // block, a captive portal or a proxy returns.
        let transport = FakeHTTPTransport()
        transport.enqueueStatus(
            200,
            body: "<!DOCTYPE html><html><head><title>Betfair</title></head></html>",
            headers: ["Content-Type": "text/html; charset=utf-8"])
        let session = makeSession(transport)

        do {
            _ = try await session.token()
            XCTFail("expected the login to fail")
        } catch let failure as BetfairLoginFailure {
            XCTAssertTrue(failure.isUnreadableResponse)
            XCTAssertEqual(failure.code, "UNREADABLE_RESPONSE")
            let detail = failure.detail ?? "no detail"
            XCTAssertTrue(detail.contains("text/html"), detail)
            XCTAssertTrue(detail.contains("200"), detail)
        } catch {
            XCTFail("expected BetfairLoginFailure, got \(error)")
        }
    }

    func test_theMessageSaysTheCredentialsWereNeverChecked() {
        // The instruction matters more than the wording. The old message sent
        // the user back to re-type a password that was never read.
        let failure = BetfairLoginFailure.unreadableResponse(
            HTTPResponseShape(
                statusCode: 200, contentType: "text/html", body: Data("<html>".utf8)))

        XCTAssertTrue(failure.message.contains("never checked"), failure.message)
        XCTAssertTrue(failure.message.contains("text/html"), failure.message)
        XCTAssertFalse(failure.isBadCredentials)
        XCTAssertFalse(failure.isInformational)
    }

    func test_anUnreadableReplyIsNotLatchedAsPermanent() async throws {
        // A cert requirement or a 2FA challenge is latched, because retrying it
        // is pointless and could lock the account. This is not that: the cause
        // is outside the account and may be gone on the next attempt, so a
        // second tap must actually try again rather than replay the failure.
        let transport = FakeHTTPTransport()
        transport.enqueueStatus(
            200, body: "<html></html>", headers: ["Content-Type": "text/html"])
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        let session = makeSession(transport)

        do {
            _ = try await session.token()
            XCTFail("expected the first login to fail")
        } catch is BetfairLoginFailure {
            // Expected.
        }

        let token = try await session.token()

        XCTAssertEqual(token, "SESSION-TOKEN-ABC123")
        XCTAssertEqual(transport.requests.count, 2, "the second attempt must reach the network")
    }

    func test_aRealBetfairRefusalStillReportsBetfairsOwnCode() async {
        // The regression guard for the rewrite: reading the body as raw data
        // first must not cost the normal path its code.
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(#"{"token":"","product":"","status":"FAIL","error":"CERT_AUTH_REQUIRED"}"#)
        let session = makeSession(transport)

        do {
            _ = try await session.token()
            XCTFail("expected the login to fail")
        } catch let failure as BetfairLoginFailure {
            XCTAssertEqual(failure.code, "CERT_AUTH_REQUIRED")
            XCTAssertFalse(failure.isUnreadableResponse)
            XCTAssertTrue(failure.requiresCertificateLogin)
            XCTAssertNil(failure.detail)
        } catch {
            XCTFail("expected BetfairLoginFailure, got \(error)")
        }
    }

    func test_validJSONOfTheWrongShapeIsNotMistakenForAnUnreadableReply() async {
        // Every field on the login response is optional, so a JSON object that
        // happens to carry none of them decodes fine and falls through to the
        // ordinary failure path. Worth pinning: it is the boundary between the
        // two branches.
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(#"{"somethingElse":true}"#)
        let session = makeSession(transport)

        do {
            _ = try await session.token()
            XCTFail("expected the login to fail")
        } catch let failure as BetfairLoginFailure {
            XCTAssertFalse(failure.isUnreadableResponse)
            XCTAssertEqual(failure.code, "UNKNOWN")
        } catch {
            XCTFail("expected BetfairLoginFailure, got \(error)")
        }
    }
}
