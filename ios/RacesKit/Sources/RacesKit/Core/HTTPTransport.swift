import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The seam between our networking code and `URLSession`.
///
/// Every provider client talks to this rather than to `URLSession` directly, so
/// the whole stack — request building, status mapping, decoding, retries, rate
/// limiting — is exercised on Linux against committed fixtures, with no network.
public protocol HTTPPerforming: AnyObject {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The live transport.
public final class URLSessionTransport: HTTPPerforming {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// A session with timeouts suited to racing data: the free tier is slow and
    /// bulk-oriented, so a short timeout causes more failures than it prevents.
    public static func makeDefaultSession(timeout: TimeInterval = 30) -> URLSession {
        // Deliberately minimal: only the two timeout knobs, which exist on both
        // Darwin Foundation and swift-corelibs-foundation. Options that are
        // Darwin-only would break the Linux build of this package.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network(URLError(.badServerResponse))
        }
        return (data, http)
    }
}
