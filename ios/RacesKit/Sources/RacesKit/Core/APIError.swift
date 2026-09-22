import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unified error type for every provider call in the app.
///
/// Cases classify failures so the UI can show friendly, non-technical copy and
/// the networking layer can decide whether a request is worth retrying. Use
/// ``APIError/from(_:)`` to normalise any thrown `Error` into an `APIError`.
public enum APIError: Error, LocalizedError, Equatable {
    /// Device is offline or the host is unreachable.
    case offline
    /// The request exceeded its timeout.
    case timedOut
    /// Other transport-level failure (carries the underlying `URLError`).
    case network(URLError)
    /// 401 — credentials missing, wrong, or (Betfair) an expired session token.
    case unauthorized
    /// 403 — authenticated but not allowed.
    case forbidden
    /// 404 — resource not found.
    case notFound
    /// 409 — conflicting state.
    case conflict
    /// 400 / 422 — invalid request. Carries the server's plain-text message.
    case badRequest(serverMessage: String?)
    /// 429 — rate limited. Carries the parsed `Retry-After` delay if present.
    case rateLimited(retryAfter: TimeInterval?)
    /// 5xx and any other unexpected status. Carries status + server message.
    case server(status: Int, serverMessage: String?)
    /// The response body could not be decoded into the expected type.
    ///
    /// Carries the shape of what arrived instead, when there was a response to
    /// describe. Without it this case says only "something unexpected" — which
    /// names nothing the reader can act on, and nothing they can report.
    case decoding(HTTPResponseShape?)
    /// The endpoint exists but the user's subscription tier doesn't include it.
    ///
    /// Distinct from ``forbidden`` on purpose: this is a *normal, expected* state
    /// on the free tier, not a failure. The rating engine catches it and drops the
    /// factors that endpoint would have fed, rather than failing the whole race.
    case tierUnavailable(feature: String)
    /// A provider the app needs has not been configured with credentials yet.
    /// Also a normal state — the app is designed to work with either provider absent.
    case notConfigured(provider: String)

    /// `URLError` codes that represent transient connectivity blips worth retrying.
    private static let transientURLCodes: Set<URLError.Code> = [
        .networkConnectionLost,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .resourceUnavailable,
    ]

    /// Whether automatically retrying the request could plausibly succeed.
    /// Only meaningful for idempotent requests — the caller gates on the HTTP method.
    public var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .rateLimited:
            return true
        case .server(let status, _):
            return status >= 500
        case .network(let error):
            return Self.transientURLCodes.contains(error.code)
        case .unauthorized, .forbidden, .notFound, .conflict, .badRequest, .decoding,
             .tierUnavailable, .notConfigured:
            return false
        }
    }

    /// Whether this represents an expected limitation rather than something going
    /// wrong. The UI reports these as plain information, never as an error state.
    public var isExpectedLimitation: Bool {
        switch self {
        case .tierUnavailable, .notConfigured:
            return true
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "You're offline. Check your connection and try again."
        case .timedOut:
            return "The request timed out. Please try again."
        case .network:
            return "Couldn't reach the racing data provider. Please try again."
        case .unauthorized:
            return "Those credentials weren't accepted. Check them in Settings."
        case .forbidden:
            return "Your account doesn't have access to that."
        case .notFound:
            return "We couldn't find what you were looking for."
        case .conflict:
            return "That change conflicts with the current data. Refresh and try again."
        case .badRequest(let serverMessage):
            return Self.cleaned(serverMessage) ?? "That request couldn't be completed."
        case .rateLimited:
            return "Too many requests. Please wait a moment and try again."
        case .server(_, let serverMessage):
            return Self.cleaned(serverMessage) ?? "The provider had a problem. Please try again."
        case .decoding(let shape):
            guard let shape else {
                return "We received an unexpected response. Please try again."
            }
            return "We couldn't read the reply — \(shape)"
        case .tierUnavailable(let feature):
            return "\(feature) isn't included in your subscription tier."
        case .notConfigured(let provider):
            return "\(provider) hasn't been set up yet."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .offline:
            return "Make sure Wi-Fi or mobile data is turned on."
        case .unauthorized:
            return "Re-enter your username and password in Settings."
        case .tierUnavailable:
            return "Tips will still be produced, using fewer factors."
        case .notConfigured(let provider):
            return "Add your \(provider) details in Settings."
        default:
            return nil
        }
    }

    /// Normalise any thrown error into an `APIError`, mapping `URLError` codes to
    /// the appropriate transport case. Already-`APIError` values pass through.
    public static func from(_ error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .timedOut:
                return .timedOut
            default:
                return .network(urlError)
            }
        }
        return .network(URLError(.unknown))
    }

    /// Trim a server-provided message and reject anything empty or implausibly
    /// long (so we never dump a stray HTML page or stack trace at the user).
    private static func cleaned(_ message: String?) -> String? {
        guard let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= 200 else {
            return nil
        }
        return trimmed
    }

    // MARK: - Equatable

    public static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.offline, .offline),
             (.timedOut, .timedOut),
             (.unauthorized, .unauthorized),
             (.forbidden, .forbidden),
             (.notFound, .notFound),
             (.conflict, .conflict):
            return true
        case let (.decoding(a), .decoding(b)):
            return a == b
        case let (.network(a), .network(b)):
            return a.code == b.code
        case let (.badRequest(a), .badRequest(b)):
            return a == b
        case let (.rateLimited(a), .rateLimited(b)):
            return a == b
        case let (.server(sa, ma), .server(sb, mb)):
            return sa == sb && ma == mb
        case let (.tierUnavailable(a), .tierUnavailable(b)):
            return a == b
        case let (.notConfigured(a), .notConfigured(b)):
            return a == b
        default:
            return false
        }
    }
}
