import Foundation

/// Why an interactive login did not produce a session token.
///
/// The raw `code` is always preserved, because this type exists to answer the
/// one question the design could not settle offline: **does interactive login
/// work for this account, or does Betfair insist on a certificate?**
///
/// Betfair returns HTTP 200 with `status: "FAIL"` and the reason in `error`, so
/// a status-code check alone reports success. Everything here keys off the body.
public struct BetfairLoginFailure: Error, Hashable, Sendable, CustomStringConvertible {

    /// Betfair's own code, verbatim — `INVALID_USERNAME_OR_PASSWORD`,
    /// `SECURITY_QUESTION_REQUIRED`, `CERT_AUTH_REQUIRED` and so on. Kept raw
    /// because an unrecognised code is exactly the interesting case, and
    /// collapsing it into a generic error would throw away the finding.
    public let code: String

    public init(code: String) {
        self.code = code
    }

    /// Interactive login can never succeed for this account: the app has to use
    /// certificate login instead.
    ///
    /// This is the reshaping answer. If it comes back true, the client needs a
    /// `URLSessionDelegate` supplying a client identity from the Keychain, and
    /// the credential fields in Settings change shape too.
    public var requiresCertificateLogin: Bool {
        ["CERT_AUTH_REQUIRED", "SECURITY_RESTRICTED_LOCATION"].contains(code)
    }

    /// The account needs a human in a browser — two-factor, a security question,
    /// a forced password change, terms to accept. Retrying with the same
    /// credentials cannot help, so the UI must say so rather than offering one.
    public var requiresUserAction: Bool {
        [
            "SECURITY_QUESTION_REQUIRED",
            "PENDING_AUTH",
            "ACCOUNT_PENDING_PASSWORD_CHANGE",
            "ACCOUNT_NOW_LOCKED",
            "ACCOUNT_ALREADY_LOCKED",
            "TEMPORARY_BAN_TOO_MANY_REQUESTS",
            "ACTIONS_REQUIRED",
            "DUPLICATE_CARDS",
            "CHANGE_PASSWORD_REQUIRED",
            "CLOSED_ACCOUNT",
            "SUSPENDED_ACCOUNT",
            "SELF_EXCLUDED",
            "TRADING_MASTER_SUSPENDED",
        ].contains(code)
    }

    /// Just wrong. The only failure where re-entering credentials is the answer.
    public var isBadCredentials: Bool {
        ["INVALID_USERNAME_OR_PASSWORD", "INVALID_USERNAME", "INVALID_PASSWORD"].contains(code)
    }

    /// Plain copy for the UI. Never phrased as "check your password" unless that
    /// is actually what happened — being told the wrong thing to fix is worse
    /// than being told nothing.
    public var message: String {
        if requiresCertificateLogin {
            return "Betfair requires a certificate login for this account, which this app doesn't support yet."
        }
        if isBadCredentials {
            return "Betfair didn't recognise that username and password."
        }
        if requiresUserAction {
            return "Betfair needs you to sign in on their website first (\(code))."
        }
        return "Betfair refused the login (\(code))."
    }

    public var description: String { "BetfairLoginFailure(\(code))" }

    /// How the rest of the app should react.
    ///
    /// `.unauthorized` only for genuinely bad credentials. Everything else maps
    /// to `.badRequest` carrying the code, because "your credentials are wrong"
    /// is the wrong instruction for a 2FA challenge and would send the user round
    /// in circles re-typing a correct password.
    public var asAPIError: APIError {
        isBadCredentials ? .unauthorized : .badRequest(serverMessage: message)
    }
}

/// A live Betfair session.
public struct BetfairSessionToken: Hashable, Sendable {
    public let token: String
    public let obtainedAt: Date

    public init(token: String, obtainedAt: Date = Date()) {
        self.token = token
        self.obtainedAt = obtainedAt
    }

    /// Betfair's documented idle and absolute session lifetimes could not be
    /// confirmed offline — their docs host is unreachable from the build
    /// environment. Rather than guess a number and silently expire a good
    /// session, the client re-authenticates when the exchange says the session
    /// is invalid, and this is only used to decide when a keep-alive is worth
    /// sending.
    ///
    /// Four hours is deliberately conservative against the commonly cited
    /// twelve. Record the real figures in `docs/providers.md` once measured.
    public static let keepAliveAfter: TimeInterval = 4 * 60 * 60

    public func isWorthKeepingAlive(now: Date = Date()) -> Bool {
        now.timeIntervalSince(obtainedAt) >= Self.keepAliveAfter
    }
}
