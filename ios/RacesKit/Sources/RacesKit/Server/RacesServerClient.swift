import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Races server, as the app needs it.
///
/// A protocol so view models are tested against a fake and never touch the
/// network. The server does everything the app used to: it calls The Racing
/// API and Betfair, rates, seals, settles and retrains. The app reads.
public protocol RacesServing: AnyObject, Sendable {
    func status() async throws -> ServerStatus
    func backtests() async throws -> [ServerBacktest]
    func courses() async throws -> [Course]
    func racecard(day: RaceDay) async throws -> ServerRacecard
    func race(id: String) async throws -> ServerRaceDetail
    func record(weightsID: String?) async throws -> ServerRecord
    func model() async throws -> ServerModel
    /// Ask the server to run a job now — `results`, `cards`, `tips`.
    func runJob(_ name: String) async throws
}

/// The live client: HTTPS to the homelab, bearer token from the Keychain.
public final class RacesServerClient: RacesServing, @unchecked Sendable {

    private let http: HTTPClient
    private let token: String

    public init(configuration: ServerConfiguration, transport: any HTTPPerforming) {
        self.token = configuration.token
        // No pacing: the server is ours, and it does the provider rate
        // limiting itself.
        self.http = HTTPClient(
            baseURL: configuration.baseURL,
            transport: transport,
            requestsPerSecond: 0,
            retryPolicy: .default,
            decoder: Self.decoder)
    }

    /// The server writes whole-second UTC ISO-8601, which is exactly what
    /// `.iso8601` accepts.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var authorization: HTTPAuthorization {
        .headers(["Authorization": "Bearer \(token)"])
    }

    private struct CoursesPage: Decodable {
        let courses: [Course]
    }

    private struct BacktestsPage: Decodable {
        let backtests: [ServerBacktest]
    }

    private struct JobReply: Decodable {
        let job: String
    }

    public func status() async throws -> ServerStatus {
        try await http.get("v1/status", authorization: authorization)
    }

    public func backtests() async throws -> [ServerBacktest] {
        let page: BacktestsPage = try await http.get("v1/backtests", authorization: authorization)
        return page.backtests
    }

    public func courses() async throws -> [Course] {
        let page: CoursesPage = try await http.get("v1/courses", authorization: authorization)
        return page.courses
    }

    public func racecard(day: RaceDay) async throws -> ServerRacecard {
        try await http.get(
            "v1/racecards",
            query: [URLQueryItem(name: "day", value: day.rawValue)],
            authorization: authorization)
    }

    public func race(id: String) async throws -> ServerRaceDetail {
        try await http.get("v1/races/\(id)", authorization: authorization)
    }

    public func record(weightsID: String?) async throws -> ServerRecord {
        let query = weightsID.map { [URLQueryItem(name: "weightsID", value: $0)] } ?? []
        return try await http.get("v1/record", query: query, authorization: authorization)
    }

    public func model() async throws -> ServerModel {
        try await http.get("v1/model", authorization: authorization)
    }

    public func runJob(_ name: String) async throws {
        let _: JobReply = try await http.post(
            "v1/admin/jobs/\(name)",
            body: Data(),
            contentType: "application/json",
            authorization: authorization)
    }
}
