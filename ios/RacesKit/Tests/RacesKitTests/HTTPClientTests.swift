import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RacesKit

private struct Payload: Codable, Equatable {
    let name: String
    let count: Int
}

final class HTTPClientTests: XCTestCase {
    private var transport: FakeHTTPTransport!

    override func setUp() {
        super.setUp()
        transport = FakeHTTPTransport()
    }

    private func makeClient(
        requestsPerSecond: Double = 1000,
        retryPolicy: RetryPolicy = .none
    ) -> HTTPClient {
        HTTPClient(
            baseURL: URL(string: "https://api.example.com")!,
            transport: transport,
            requestsPerSecond: requestsPerSecond,
            retryPolicy: retryPolicy
        )
    }

    // MARK: - Request building

    func test_get_buildsURLFromBaseAndPath() async throws {
        transport.enqueueJSON(#"{"name":"Ascot","count":7}"#)
        let client = makeClient()

        let payload: Payload = try await client.get("/v1/courses")

        XCTAssertEqual(payload, Payload(name: "Ascot", count: 7))
        XCTAssertEqual(transport.lastRequest?.url?.absoluteString, "https://api.example.com/v1/courses")
        XCTAssertEqual(transport.lastRequest?.httpMethod, "GET")
    }

    func test_get_leadingSlashIsOptional() async throws {
        transport.enqueueJSON(#"{"name":"a","count":1}"#)
        transport.enqueueJSON(#"{"name":"a","count":1}"#)
        let client = makeClient()

        let _: Payload = try await client.get("/v1/courses")
        let _: Payload = try await client.get("v1/courses")

        XCTAssertEqual(transport.requests[0].url, transport.requests[1].url)
    }

    func test_get_appendsQueryItems() async throws {
        transport.enqueueJSON(#"{"name":"a","count":1}"#)
        let client = makeClient()

        let _: Payload = try await client.get(
            "/v1/racecards/free",
            query: [URLQueryItem(name: "day", value: "today"),
                    URLQueryItem(name: "region_codes", value: "gb")]
        )

        let url = try XCTUnwrap(transport.lastRequest?.url?.absoluteString)
        XCTAssertTrue(url.contains("day=today"), url)
        XCTAssertTrue(url.contains("region_codes=gb"), url)
    }

    func test_basicAuthorization_isBase64Encoded() async throws {
        transport.enqueueJSON(#"{"name":"a","count":1}"#)
        let client = makeClient()

        let _: Payload = try await client.get(
            "/v1/courses",
            authorization: .basic(username: "user", password: "pass")
        )

        // "user:pass" base64-encoded.
        XCTAssertEqual(transport.authorizationHeader(), "Basic dXNlcjpwYXNz")
    }

    func test_headerAuthorization_setsEachHeader() async throws {
        transport.enqueueJSON(#"{"name":"a","count":1}"#)
        let client = makeClient()

        let _: Payload = try await client.get(
            "/v1/courses",
            authorization: .headers(["X-Application": "appkey", "X-Authentication": "token"])
        )

        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "X-Application"), "appkey")
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "X-Authentication"), "token")
    }

    func test_formPost_encodesBodyAndContentType() async throws {
        transport.enqueueJSON(#"{"name":"a","count":1}"#)
        let client = makeClient()

        let _: Payload = try await client.post("/api/login", form: ["username": "ben", "password": "secret"])

        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(
            transport.lastRequest?.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        let body = try XCTUnwrap(transport.bodyString())
        XCTAssertTrue(body.contains("username=ben"), body)
        XCTAssertTrue(body.contains("password=secret"), body)
    }

    /// A `+` in a form body decodes as a space, so it must be percent-encoded.
    /// Betfair passwords routinely contain one, which would otherwise fail login
    /// with a misleading "invalid credentials".
    func test_formPost_percentEncodesPlusInValues() async throws {
        transport.enqueueJSON(#"{"name":"a","count":1}"#)
        let client = makeClient()

        let _: Payload = try await client.post("/api/login", form: ["password": "a+b"])

        let body = try XCTUnwrap(transport.bodyString())
        XCTAssertTrue(body.contains("a%2Bb"), body)
        XCTAssertFalse(body.contains("a+b"), body)
    }

    // MARK: - Status mapping

    func test_statusMapping() async throws {
        let cases: [(Int, APIError)] = [
            (400, .badRequest(serverMessage: "bad")),
            (401, .unauthorized),
            (403, .forbidden),
            (404, .notFound),
            (409, .conflict),
            (422, .badRequest(serverMessage: "bad")),
            (500, .server(status: 500, serverMessage: "bad")),
            (503, .server(status: 503, serverMessage: "bad")),
        ]

        for (status, expected) in cases {
            let transport = FakeHTTPTransport()
            transport.enqueueStatus(status, body: "bad")
            let client = HTTPClient(
                baseURL: URL(string: "https://api.example.com")!,
                transport: transport,
                requestsPerSecond: 1000,
                retryPolicy: .none
            )

            do {
                let _: Payload = try await client.get("/thing")
                XCTFail("Expected \(status) to throw")
            } catch let error as APIError {
                XCTAssertEqual(error, expected, "status \(status)")
            }
        }
    }

    func test_rateLimited_parsesRetryAfterHeader() async throws {
        transport.enqueueStatus(429, headers: ["Retry-After": "3"])
        let client = makeClient()

        do {
            let _: Payload = try await client.get("/thing")
            XCTFail("Expected 429 to throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 3))
        }
    }

    func test_malformedBody_throwsDecoding() async throws {
        transport.enqueueJSON("not json at all")
        let client = makeClient()

        do {
            let _: Payload = try await client.get("/thing")
            XCTFail("Expected a decoding failure")
        } catch let error as APIError {
            XCTAssertEqual(error, .decoding)
        }
    }

    // MARK: - Retries

    func test_get_retriesTransientServerErrors() async throws {
        transport.enqueueStatus(503, body: "down")
        transport.enqueueJSON(#"{"name":"Ascot","count":7}"#)
        let client = makeClient(retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0.001, maxDelay: 0.01))

        let payload: Payload = try await client.get("/thing")

        XCTAssertEqual(payload.name, "Ascot")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func test_get_doesNotRetryClientErrors() async throws {
        transport.enqueueStatus(404)
        let client = makeClient(retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0.001, maxDelay: 0.01))

        do {
            let _: Payload = try await client.get("/thing")
            XCTFail("Expected 404 to throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .notFound)
        }
        XCTAssertEqual(transport.requests.count, 1, "404 is not retryable")
    }

    /// A retried POST could double-submit. Nothing we POST is a mutation today,
    /// and this test is what keeps that true.
    func test_post_isNotRetried() async throws {
        transport.enqueueStatus(503, body: "down")
        transport.enqueueJSON(#"{"name":"Ascot","count":7}"#)
        let client = makeClient(retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0.001, maxDelay: 0.01))

        do {
            let _: Payload = try await client.post("/thing", form: ["a": "b"])
            XCTFail("Expected 503 to throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 503, serverMessage: "down"))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func test_get_givesUpAfterMaxAttempts() async throws {
        for _ in 0..<5 { transport.enqueueStatus(503, body: "down") }
        let client = makeClient(retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0.001, maxDelay: 0.01))

        do {
            let _: Payload = try await client.get("/thing")
            XCTFail("Expected to give up")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 503, serverMessage: "down"))
        }
        XCTAssertEqual(transport.requests.count, 3)
    }
}
