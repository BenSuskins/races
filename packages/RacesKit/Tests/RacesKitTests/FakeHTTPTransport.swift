import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RacesKit

/// A scripted `HTTPPerforming` for tests.
///
/// Queue up responses and it hands them out in order, recording every request it
/// saw so tests can assert on URLs, headers and bodies. This is what lets the
/// whole networking stack run on Linux with no network and no credentials.
final class FakeHTTPTransport: HTTPPerforming, @unchecked Sendable {
    enum Step {
        case success(status: Int, body: Data, headers: [String: String])
        case failure(Error)
    }

    private(set) var requests: [URLRequest] = []
    private var steps: [Step] = []

    /// Returned once the scripted steps run out, so a test that under-scripts
    /// fails with a clear message rather than an index-out-of-range crash.
    var fallback: Step = .failure(APIError.server(status: 599, serverMessage: "FakeHTTPTransport ran out of scripted responses"))

    init(steps: [Step] = []) {
        self.steps = steps
    }

    // MARK: - Scripting

    func enqueue(_ step: Step) {
        steps.append(step)
    }

    func enqueueJSON(_ json: String, status: Int = 200, headers: [String: String] = [:]) {
        enqueue(.success(status: status, body: Data(json.utf8), headers: headers))
    }

    func enqueueStatus(_ status: Int, body: String = "", headers: [String: String] = [:]) {
        enqueue(.success(status: status, body: Data(body.utf8), headers: headers))
    }

    func enqueueFailure(_ error: Error) {
        enqueue(.failure(error))
    }

    // MARK: - HTTPPerforming

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let step = steps.isEmpty ? fallback : steps.removeFirst()
        switch step {
        case .failure(let error):
            throw error
        case .success(let status, let body, let headers):
            let url = request.url ?? URL(string: "https://example.invalid")!
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                throw APIError.decoding(nil)
            }
            return (body, response)
        }
    }

    // MARK: - Assertions helpers

    var lastRequest: URLRequest? { requests.last }

    func authorizationHeader(at index: Int = 0) -> String? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index].value(forHTTPHeaderField: "Authorization")
    }

    func bodyString(at index: Int = 0) -> String? {
        guard requests.indices.contains(index), let body = requests[index].httpBody else { return nil }
        return String(data: body, encoding: .utf8)
    }
}
