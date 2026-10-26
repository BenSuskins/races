import XCTest
@testable import RacesKit

final class BetfairSessionTests: XCTestCase {

    private let credentials = BetfairCredentials(
        appKey: "APPKEY", username: "ben", password: "pa+ssword")

    private func makeSession(
        _ transport: FakeHTTPTransport,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000_000) }
    ) -> BetfairSession {
        BetfairSession(
            credentials: credentials,
            transport: transport,
            requestsPerSecond: 1000,
            now: now)
    }

    // MARK: - Login

    func test_aSuccessfulLoginYieldsAToken() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        let session = makeSession(transport)

        let token = try await session.token()

        XCTAssertEqual(token, "SESSION-TOKEN-ABC123")
    }

    func test_theAppKeyGoesOnTheLoginRequestAndThePasswordInTheBody() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        let session = makeSession(transport)

        _ = try await session.token()

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Application"), "APPKEY")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded")
    }

    func test_aPlusInThePasswordSurvivesTheFormEncoding() async throws {
        // A raw `+` in a form body decodes as a space, so this password would
        // arrive as "pa ssword" and the login would fail with what looks like
        // wrong credentials. Betfair passwords routinely contain one.
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        let session = makeSession(transport)

        _ = try await session.token()

        let body = try XCTUnwrap(transport.bodyString(at: 0))
        XCTAssertTrue(body.contains("pa%2Bssword"), "Expected an escaped plus, got: \(body)")
        XCTAssertFalse(body.contains("pa+ssword"))
    }

    func test_theTokenIsReusedRatherThanReAuthenticating() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        let session = makeSession(transport)

        _ = try await session.token()
        _ = try await session.token()

        XCTAssertEqual(transport.requests.count, 1)
    }

    func test_invalidatingForcesAFreshLogin() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        let session = makeSession(transport)

        _ = try await session.token()
        await session.invalidate()
        _ = try await session.token()

        XCTAssertEqual(transport.requests.count, 2)
    }

    // MARK: - The spike's actual question

    func test_aTwoFactorChallengeIsReportedAsSuchAndNotAsABadPassword() async throws {
        // Betfair answers a 2FA challenge with HTTP 200 and status FAIL, so a
        // status-code check reads it as a success with no token. This is also
        // the whole point of the M1 spike: if it happens, the design changes.
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-2fa.json"))
        let session = makeSession(transport)

        do {
            _ = try await session.token()
            XCTFail("Expected a login failure")
        } catch let failure as BetfairLoginFailure {
            XCTAssertEqual(failure.code, "SECURITY_QUESTION_REQUIRED")
            XCTAssertTrue(failure.requiresUserAction)
            XCTAssertFalse(
                failure.isBadCredentials,
                "Telling the user to re-check a correct password sends them round in circles")
            XCTAssertFalse(failure.requiresCertificateLogin)
        }
    }

    func test_aCertificateRequirementIsFlaggedBecauseItReshapesTheDesign() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-certrequired.json"))
        let session = makeSession(transport)

        do {
            _ = try await session.token()
            XCTFail("Expected a login failure")
        } catch let failure as BetfairLoginFailure {
            XCTAssertTrue(failure.requiresCertificateLogin)
            XCTAssertTrue(failure.message.contains("certificate"))
        }
    }

    func test_aPermanentFailureIsNotRetriedOnEveryCall() async throws {
        // Retrying a 2FA challenge on every card refresh would look like a hang
        // and could get the account locked.
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-2fa.json"))
        let session = makeSession(transport)

        _ = try? await session.token()
        _ = try? await session.token()
        _ = try? await session.token()

        XCTAssertEqual(transport.requests.count, 1, "Only the first attempt should reach Betfair")
    }

    func test_badCredentialsAreRetryableBecauseTheUserCanFixThem() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(
            #"{"token":"","status":"FAIL","error":"INVALID_USERNAME_OR_PASSWORD"}"#)
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        let session = makeSession(transport)

        do {
            _ = try await session.token()
            XCTFail("Expected a failure")
        } catch let failure as BetfairLoginFailure {
            XCTAssertTrue(failure.isBadCredentials)
            XCTAssertEqual(failure.asAPIError, .unauthorized)
        }

        // Not latched, so correcting the password works without a relaunch.
        let token = try await session.token()
        XCTAssertEqual(token, "SESSION-TOKEN-ABC123")
    }

    func test_aFailWithNoErrorStillProducesACode() async throws {
        // Defensive: a success-shaped body with no token and no error would
        // otherwise report as a login that worked.
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(#"{"token":"","status":"FAIL","error":""}"#)
        let session = makeSession(transport)

        do {
            _ = try await session.token()
            XCTFail("Expected a failure")
        } catch let failure as BetfairLoginFailure {
            XCTAssertEqual(failure.code, "FAIL")
        }
    }

    func test_incompleteCredentialsNeverReachTheNetwork() async {
        let transport = FakeHTTPTransport()
        let session = BetfairSession(
            credentials: BetfairCredentials(appKey: "APPKEY", username: "ben", password: ""),
            transport: transport,
            requestsPerSecond: 1000)

        do {
            _ = try await session.token()
            XCTFail("Expected notConfigured")
        } catch {
            XCTAssertEqual(APIError.from(error), .notConfigured(provider: "Betfair"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - Keep-alive

    func test_aFreshSessionIsNotKeptAlive() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        let session = makeSession(transport)
        _ = try await session.token()

        let didCall = try await session.keepAliveIfNeeded()

        XCTAssertFalse(didCall, "No point spending a request on a session minutes old")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func test_anOldSessionIsKeptAlive() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        transport.enqueueJSON(#"{"token":"REFRESHED","status":"SUCCESS","error":""}"#)

        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let session = makeSession(transport, now: { clock.now })
        _ = try await session.token()

        clock.advance(by: BetfairSessionToken.keepAliveAfter + 1)
        let didCall = try await session.keepAliveIfNeeded()

        XCTAssertTrue(didCall)
        let token = try await session.token()
        XCTAssertEqual(token, "REFRESHED")
    }

    func test_aRefusedKeepAliveDropsTheSessionRatherThanKeepingADeadToken() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        transport.enqueueJSON(#"{"token":"","status":"FAIL","error":"NO_SESSION"}"#)
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))

        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let session = makeSession(transport, now: { clock.now })
        _ = try await session.token()

        clock.advance(by: BetfairSessionToken.keepAliveAfter + 1)
        let didCall = try await session.keepAliveIfNeeded()
        XCTAssertFalse(didCall)

        let hasToken = await session.hasToken
        XCTAssertFalse(hasToken)

        // And the next call logs in again rather than sending a dead token.
        _ = try await session.token()
        XCTAssertEqual(transport.requests.count, 3)
    }
}

/// A clock a test can move. `final class` with a lock so it can be captured by a
/// `@Sendable` closure without the compiler objecting.
///
/// Explicit `lock()`/`unlock()` rather than `withLock`: this suite runs on
/// swift-corelibs-foundation as well as Darwin, and the two-call form is the one
/// that unambiguously exists on both.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}
