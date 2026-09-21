import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How a request authenticates itself. Resolved per-request rather than baked in
/// at init, because Betfair's session token expires and has to be refreshed
/// mid-flight while the Racing API's Basic credentials never change.
public enum HTTPAuthorization: Sendable {
    case none
    case basic(username: String, password: String)
    /// A literal header pair, e.g. Betfair's `X-Authentication: <sessionToken>`.
    case headers([String: String])
}

/// Shared request pipeline: build → rate limit → send → validate → decode,
/// wrapped in bounded retries for idempotent methods.
///
/// Both provider clients are thin layers over this. Keeping the pipeline in one
/// place means rate limiting and status mapping can't drift between them.
/// `@unchecked Sendable`: every stored property is a `let`, and the one
/// non-`Sendable` member — the decoder — is only ever read.
public final class HTTPClient: @unchecked Sendable {
    private let baseURL: URL
    private let transport: any HTTPPerforming
    private let limiter: RateLimiter
    private let retryPolicy: RetryPolicy
    private let decoder: JSONDecoder

    /// Methods safe to retry automatically. A retried POST could double-submit;
    /// nothing we POST is a mutation, but the gate stays so that stays true.
    private static let idempotentMethods: Set<String> = ["GET", "PUT", "DELETE"]

    /// Shared because it is only ever read, never reconfigured, and is used as a
    /// default argument.
    ///
    /// This carried `nonisolated(unsafe)` on the belief that `JSONDecoder` is not
    /// `Sendable`. It is — the compiler says so itself where the same attribute
    /// was flagged as unnecessary elsewhere — so the annotation was both
    /// redundant and a misleading comment.
    public static let defaultDecoder = JSONDecoder()

    public init(
        baseURL: URL,
        transport: any HTTPPerforming,
        requestsPerSecond: Double,
        retryPolicy: RetryPolicy = .default,
        decoder: JSONDecoder = HTTPClient.defaultDecoder
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.limiter = RateLimiter(requestsPerSecond: requestsPerSecond)
        self.retryPolicy = retryPolicy
        self.decoder = decoder
    }

    // MARK: - Verbs

    public func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        authorization: HTTPAuthorization = .none,
        as type: T.Type = T.self
    ) async throws -> T {
        let data = try await performValidated(
            method: "GET", path: path, query: query, body: nil,
            contentType: nil, authorization: authorization
        )
        return try decode(data, as: type)
    }

    public func post<T: Decodable>(
        _ path: String,
        json body: some Encodable,
        authorization: HTTPAuthorization = .none,
        as type: T.Type = T.self
    ) async throws -> T {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw APIError.decoding
        }
        let data = try await performValidated(
            method: "POST", path: path, query: [], body: encoded,
            contentType: "application/json", authorization: authorization
        )
        return try decode(data, as: type)
    }

    /// Form-encoded POST. Betfair's identity endpoints take
    /// `application/x-www-form-urlencoded`, not JSON.
    public func post<T: Decodable>(
        _ path: String,
        form: [String: String],
        authorization: HTTPAuthorization = .none,
        as type: T.Type = T.self
    ) async throws -> T {
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        // `URLComponents` percent-encodes for a query string, which leaves `+`
        // literal — in a form body that decodes as a space. Encode it explicitly.
        let encoded = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")

        let data = try await performValidated(
            method: "POST", path: path, query: [], body: Data(encoded.utf8),
            contentType: "application/x-www-form-urlencoded", authorization: authorization
        )
        return try decode(data, as: type)
    }

    // MARK: - Pipeline

    private func performValidated(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        contentType: String?,
        authorization: HTTPAuthorization
    ) async throws -> Data {
        let isIdempotent = Self.idempotentMethods.contains(method)
        return try await withRetry(
            policy: retryPolicy,
            shouldRetry: { isIdempotent && $0.isRetryable }
        ) {
            let request = try self.buildRequest(
                method: method, path: path, query: query,
                body: body, contentType: contentType, authorization: authorization
            )
            try await self.limiter.acquire()
            let (data, response) = try await self.transport.send(request)
            try self.validate(response, data: data)
            return data
        }
    }

    private func buildRequest(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        contentType: String?,
        authorization: HTTPAuthorization
    ) throws -> URLRequest {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(trimmed),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.badRequest(serverMessage: "Couldn't build a URL for \(path)")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw APIError.badRequest(serverMessage: "Couldn't build a URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        switch authorization {
        case .none:
            break
        case .basic(let username, let password):
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        case .headers(let headers):
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return request
    }

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        throw Self.mapStatus(response, data: data)
    }

    static func mapStatus(_ response: HTTPURLResponse, data: Data) -> APIError {
        let message = String(data: data, encoding: .utf8)
        switch response.statusCode {
        case 400, 422:
            return .badRequest(serverMessage: message)
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 404:
            return .notFound
        case 409:
            return .conflict
        case 429:
            // Spelled out rather than `flatMap(TimeInterval.init)`, which is
            // ambiguous across Double's many initialisers.
            let header = response.value(forHTTPHeaderField: "Retry-After")
            return .rateLimited(retryAfter: header.flatMap { Double($0) })
        default:
            return .server(status: response.statusCode, serverMessage: message)
        }
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.decoding
        }
    }
}
