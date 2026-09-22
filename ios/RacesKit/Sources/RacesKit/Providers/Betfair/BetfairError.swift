import Foundation

/// Betfair's `APINGException` codes, as far as this app cares about them.
///
/// The reason this is its own type rather than a straight map to `APIError`:
/// `TOO_MUCH_DATA` is not a failure, it is an instruction. The batch was too
/// big and the same request will succeed if split. A plain error mapping would
/// turn a recoverable condition into a missing market.
public enum BetfairErrorCode: Hashable, Sendable {
    case invalidSession
    case invalidAppKey
    case tooMuchData
    case tooManyRequests
    case serviceBusy
    case timeout
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "INVALID_SESSION_INFORMATION", "NO_SESSION", "SESSION_EXPIRED":
            self = .invalidSession
        case "INVALID_APP_KEY", "NO_APP_KEY", "APP_KEY_CREATION_FAILED", "ACCESS_DENIED":
            self = .invalidAppKey
        case "TOO_MUCH_DATA":
            self = .tooMuchData
        case "TOO_MANY_REQUESTS":
            self = .tooManyRequests
        case "SERVICE_BUSY":
            self = .serviceBusy
        case "TIMEOUT":
            self = .timeout
        default:
            self = .other(rawValue)
        }
    }

    public var rawCode: String {
        switch self {
        case .invalidSession: return "INVALID_SESSION_INFORMATION"
        case .invalidAppKey: return "INVALID_APP_KEY"
        case .tooMuchData: return "TOO_MUCH_DATA"
        case .tooManyRequests: return "TOO_MANY_REQUESTS"
        case .serviceBusy: return "SERVICE_BUSY"
        case .timeout: return "TIMEOUT"
        case .other(let code): return code
        }
    }

    /// Whether re-authenticating and retrying once is worth doing. A session can
    /// lapse mid-afternoon through no fault of ours.
    public var isRecoverableBySigningInAgain: Bool {
        self == .invalidSession
    }

    public var asAPIError: APIError {
        switch self {
        case .invalidSession:
            return .unauthorized
        case .invalidAppKey:
            return .forbidden
        case .tooManyRequests:
            return .rateLimited(retryAfter: nil)
        case .serviceBusy:
            return .server(status: 503, serverMessage: "Betfair is busy")
        case .timeout:
            return .timedOut
        case .tooMuchData:
            // Should be split rather than surfaced. If it reaches here the
            // splitting has already been exhausted, so it is a real failure.
            return .badRequest(serverMessage: "Betfair: request too large even when split")
        case .other(let code):
            return .badRequest(serverMessage: "Betfair: \(code)")
        }
    }
}

/// A fault Betfair reported in the response body.
public struct BetfairFault: Error, Hashable, Sendable, CustomStringConvertible {
    public let code: BetfairErrorCode
    public let details: String?

    public init(code: BetfairErrorCode, details: String? = nil) {
        self.code = code
        self.details = details
    }

    public var description: String {
        details.map { "BetfairFault(\(code.rawCode): \($0))" } ?? "BetfairFault(\(code.rawCode))"
    }
}
