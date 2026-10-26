import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RacesKit

final class APIErrorTests: XCTestCase {

    // MARK: - Retryability

    func test_isRetryable() {
        let cases: [(APIError, Bool)] = [
            (.offline, true),
            (.timedOut, true),
            (.rateLimited(retryAfter: nil), true),
            (.server(status: 500, serverMessage: nil), true),
            (.server(status: 503, serverMessage: nil), true),
            (.network(URLError(.networkConnectionLost)), true),
            (.network(URLError(.cannotFindHost)), true),
            (.network(URLError(.badURL)), false),
            (.unauthorized, false),
            (.forbidden, false),
            (.notFound, false),
            (.conflict, false),
            (.badRequest(serverMessage: nil), false),
            (.decoding(nil), false),
            (.tierUnavailable(feature: "Form history"), false),
            (.notConfigured(provider: "Betfair"), false),
        ]

        for (error, expected) in cases {
            XCTAssertEqual(error.isRetryable, expected, "\(error)")
        }
    }

    /// A 4xx that isn't 500-range must never be retried, however it was built.
    func test_serverBelow500_isNotRetryable() {
        XCTAssertFalse(APIError.server(status: 418, serverMessage: nil).isRetryable)
    }

    // MARK: - Expected limitations

    /// The free tier and an unconfigured provider are normal states, not faults.
    /// The UI keys off this to show plain information instead of an error banner.
    func test_isExpectedLimitation() {
        XCTAssertTrue(APIError.tierUnavailable(feature: "Form history").isExpectedLimitation)
        XCTAssertTrue(APIError.notConfigured(provider: "Betfair").isExpectedLimitation)
        XCTAssertFalse(APIError.offline.isExpectedLimitation)
        XCTAssertFalse(APIError.unauthorized.isExpectedLimitation)
        XCTAssertFalse(APIError.server(status: 500, serverMessage: nil).isExpectedLimitation)
    }

    // MARK: - Normalisation

    func test_from_mapsURLErrorCodes() {
        XCTAssertEqual(APIError.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(APIError.from(URLError(.dataNotAllowed)), .offline)
        XCTAssertEqual(APIError.from(URLError(.internationalRoamingOff)), .offline)
        XCTAssertEqual(APIError.from(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(APIError.from(URLError(.badServerResponse)), .network(URLError(.badServerResponse)))
    }

    func test_from_passesThroughExistingAPIError() {
        XCTAssertEqual(APIError.from(APIError.notFound), .notFound)
        XCTAssertEqual(
            APIError.from(APIError.tierUnavailable(feature: "Form history")),
            .tierUnavailable(feature: "Form history")
        )
    }

    func test_from_unknownErrorBecomesNetwork() {
        struct Mystery: Error {}
        XCTAssertEqual(APIError.from(Mystery()), .network(URLError(.unknown)))
    }

    // MARK: - Messages

    func test_errorDescription_isAlwaysPresent() {
        let errors: [APIError] = [
            .offline, .timedOut, .network(URLError(.unknown)), .unauthorized, .forbidden,
            .notFound, .conflict, .badRequest(serverMessage: nil), .rateLimited(retryAfter: nil),
            .server(status: 500, serverMessage: nil), .decoding(nil),
            .decoding(HTTPResponseShape(
                statusCode: 200, contentType: "text/html", body: Data("<html>".utf8))),
            .tierUnavailable(feature: "Form history"), .notConfigured(provider: "Betfair"),
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) has no description")
        }
    }

    func test_serverMessage_isUsedWhenReasonable() {
        let error = APIError.badRequest(serverMessage: "Unknown region code")
        XCTAssertEqual(error.errorDescription, "Unknown region code")
    }

    /// Guards against dumping a stray HTML error page or a stack trace at the user.
    func test_serverMessage_isRejectedWhenTooLong() {
        let error = APIError.badRequest(serverMessage: String(repeating: "x", count: 201))
        XCTAssertEqual(error.errorDescription, "That request couldn't be completed.")
    }

    func test_serverMessage_isRejectedWhenBlank() {
        XCTAssertEqual(
            APIError.server(status: 500, serverMessage: "   \n ").errorDescription,
            "The provider had a problem. Please try again."
        )
    }

    func test_tierUnavailable_namesTheFeature() {
        let error = APIError.tierUnavailable(feature: "Form history")
        XCTAssertEqual(error.errorDescription, "Form history isn't included in your subscription tier.")
        XCTAssertEqual(error.recoverySuggestion, "Tips will still be produced, using fewer factors.")
    }

    // MARK: - Equatable

    func test_equality() {
        XCTAssertEqual(APIError.offline, .offline)
        XCTAssertNotEqual(APIError.offline, .timedOut)
        XCTAssertEqual(APIError.server(status: 500, serverMessage: "a"), .server(status: 500, serverMessage: "a"))
        XCTAssertNotEqual(APIError.server(status: 500, serverMessage: "a"), .server(status: 502, serverMessage: "a"))
        XCTAssertEqual(APIError.rateLimited(retryAfter: 3), .rateLimited(retryAfter: 3))
        XCTAssertNotEqual(APIError.rateLimited(retryAfter: 3), .rateLimited(retryAfter: nil))
        XCTAssertNotEqual(
            APIError.tierUnavailable(feature: "a"),
            APIError.tierUnavailable(feature: "b")
        )
        XCTAssertNotEqual(APIError.network(URLError(.timedOut)), .network(URLError(.badURL)))
    }
}
