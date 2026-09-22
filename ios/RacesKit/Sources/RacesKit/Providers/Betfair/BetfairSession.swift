import Foundation

public struct BetfairCredentials: Hashable, Sendable {
    public let appKey: String
    public let username: String
    public let password: String

    public init(appKey: String, username: String, password: String) {
        self.appKey = appKey
        self.username = username
        self.password = password
    }

    /// All three or nothing. A partial set would produce a login attempt that
    /// cannot succeed, and the user would be told their password was wrong.
    public var isComplete: Bool {
        !appKey.isEmpty && !username.isEmpty && !password.isEmpty
    }
}

/// Holds the Betfair session token and renews it.
///
/// An actor because the token is mutable state that several concurrent calls
/// will race for: a card refresh fires one `listMarketCatalogue` and up to a
/// dozen batched `listMarketBook`s, and every one of them needs the token. Left
/// unsynchronised, an expiry mid-refresh would have each of them log in
/// separately.
///
/// **The session lifetime is the one thing here that could not be settled
/// offline.** Betfair's docs host is unreachable from the build environment, so
/// rather than trusting a guessed expiry this renews reactively: the client
/// re-authenticates when the exchange itself says the session is invalid. The
/// keep-alive is a bonus, not the mechanism.
public actor BetfairSession {

    public static let identityBaseURL = URL(string: "https://identitysso.betfair.com")!
    /// Identity calls are rare — once per launch, plus a keep-alive.
    public static let identityRequestsPerSecond: Double = 1.0

    private let credentials: BetfairCredentials
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    private var current: BetfairSessionToken?
    /// Set once a failure is known to be permanent for this account, so the app
    /// stops re-attempting a login that can never work. A 2FA challenge retried
    /// every refresh would look like a hang and might lock the account.
    private var permanentFailure: BetfairLoginFailure?

    public init(
        credentials: BetfairCredentials,
        transport: any HTTPPerforming,
        baseURL: URL = BetfairSession.identityBaseURL,
        requestsPerSecond: Double = BetfairSession.identityRequestsPerSecond,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.now = now
        self.http = HTTPClient(
            baseURL: baseURL,
            transport: transport,
            requestsPerSecond: requestsPerSecond,
            retryPolicy: .default
        )
    }

    /// The current token, logging in if there isn't one.
    public func token() async throws -> String {
        if let permanentFailure {
            throw permanentFailure
        }
        if let current {
            return current.token
        }
        return try await logIn().token
    }

    /// Throw away the token so the next call authenticates again. Called when
    /// the exchange reports `INVALID_SESSION_INFORMATION`.
    public func invalidate() {
        current = nil
    }

    /// For tests and for restoring a session the app already holds.
    public func adopt(_ token: BetfairSessionToken) {
        current = token
        permanentFailure = nil
    }

    public var hasToken: Bool { current != nil }

    @discardableResult
    public func logIn() async throws -> BetfairSessionToken {
        guard credentials.isComplete else {
            throw APIError.notConfigured(provider: "Betfair")
        }

        let (body, httpResponse) = try await http.postFormForRawBody(
            "/api/login",
            form: ["username": credentials.username, "password": credentials.password],
            authorization: .headers([
                "X-Application": credentials.appKey,
                "Accept": "application/json",
            ])
        )

        let response: BetfairLoginResponse
        do {
            response = try HTTPClient.defaultDecoder.decode(
                BetfairLoginResponse.self, from: body)
        } catch {
            // Deliberately not `APIError.decoding`. That renders as "We received
            // an unexpected response. Please try again.", which is unactionable
            // and actively misleading here: trying again cannot help, and the
            // user is left re-typing a password that was never checked. This is
            // the one call in the app where what came back *instead* is the
            // finding, so it is carried rather than discarded.
            throw BetfairLoginFailure.unreadableResponse(
                HTTPResponseShape(
                    statusCode: httpResponse.statusCode,
                    contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                    body: body
                )
            )
        }

        guard response.isSuccess, let token = response.token else {
            let failure = BetfairLoginFailure(code: response.failureCode)
            // Bad credentials are worth retrying — the user can fix those. A
            // certificate requirement or a 2FA challenge is not.
            if failure.requiresCertificateLogin || failure.requiresUserAction {
                permanentFailure = failure
            }
            throw failure
        }

        let session = BetfairSessionToken(token: token, obtainedAt: now())
        current = session
        permanentFailure = nil
        return session
    }

    /// Extend the session, but only when it is old enough to be worth a request.
    ///
    /// Returns whether a call was actually made, so a caller can tell "kept
    /// alive" from "nothing to do" rather than assuming.
    @discardableResult
    public func keepAliveIfNeeded() async throws -> Bool {
        guard let current, current.isWorthKeepingAlive(now: now()) else { return false }

        let response: BetfairKeepAliveResponse = try await http.post(
            "/api/keepAlive",
            form: [:],
            authorization: .headers([
                "X-Application": credentials.appKey,
                "X-Authentication": current.token,
                "Accept": "application/json",
            ])
        )

        guard response.isSuccess else {
            // A refused keep-alive means the session is gone. Drop it and let
            // the next call log in rather than carrying a token we know is dead.
            self.current = nil
            return false
        }

        self.current = BetfairSessionToken(token: response.token ?? current.token, obtainedAt: now())
        return true
    }
}
