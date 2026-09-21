import Foundation

/// Credentials for The Racing API.
///
/// Entered by the user in Settings and held in the Keychain. Nothing is bundled in
/// the app, so there is no key to extract from the binary and no cost exposure if
/// it were.
public struct RacingAPICredentials: Hashable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var isComplete: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The Racing API client, written against the **free** tier.
///
/// A note on the endpoint names, because they are genuinely misleading:
/// `/v1/racecards/free` returns the *Basic* schema and `/v1/racecards/basic`
/// returns the *full* one. The paths here are the ones the free tier can actually
/// reach; see `docs/providers.md` for the tier of every call.
///
/// An **actor** because it caches what it learns — the detected tier, and whether
/// the paid endpoint has already refused. That is mutable state reached from
/// concurrent requests, so it needs an isolation domain of its own. Nothing else
/// in the package does, which is why the package no longer imposes one globally.
public actor RacingAPIClient: RacingDataProviding {

    public static let productionBaseURL = URL(string: "https://api.theracingapi.com")!
    /// The free tier's published limit. Everything else in the app is paced to it.
    public static let freeTierRequestsPerSecond: Double = 1.0

    private let http: HTTPClient
    private let credentials: RacingAPICredentials
    private var detectedCapability: ProviderCapability
    /// Once a tier-gated endpoint has refused, stop asking. Twenty runners in a
    /// race would otherwise mean twenty 403s, each one burning a rate-limit slot
    /// that a useful request could have had.
    private var formHistoryRefused = false

    public init(
        credentials: RacingAPICredentials,
        transport: any HTTPPerforming,
        baseURL: URL = RacingAPIClient.productionBaseURL,
        requestsPerSecond: Double = RacingAPIClient.freeTierRequestsPerSecond,
        retryPolicy: RetryPolicy = .default,
        assumedCapability: ProviderCapability = .free
    ) {
        self.credentials = credentials
        self.detectedCapability = assumedCapability
        self.http = HTTPClient(
            baseURL: baseURL,
            transport: transport,
            requestsPerSecond: requestsPerSecond,
            retryPolicy: retryPolicy,
            decoder: Self.decoder
        )
    }

    /// `.convertFromSnakeCase` rather than ~60 hand-written `CodingKeys`, which is
    /// both less code and fewer places to typo a wire key.
    nonisolated(unsafe) static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public var capability: ProviderCapability {
        detectedCapability
    }

    private var authorization: HTTPAuthorization {
        .basic(username: credentials.username, password: credentials.password)
    }

    // MARK: - Courses

    public func courses(regionCodes: [String]) async throws -> [Course] {
        try requireCredentials()
        let page: RacingAPICoursesPage = try await http.get(
            "/v1/courses",
            query: regionCodes.map { URLQueryItem(name: "region_codes", value: $0) },
            authorization: authorization
        )
        return (page.courses ?? []).compactMap(RacingAPIMapping.course(from:))
    }

    // MARK: - Racecards

    public func racecards(day: RaceDay, regionCodes: [String]) async throws -> [Race] {
        try requireCredentials()
        var query = [URLQueryItem(name: "day", value: day.queryValue)]
        query += regionCodes.map { URLQueryItem(name: "region_codes", value: $0) }

        let page: RacingAPIRacecardsPage = try await http.get(
            "/v1/racecards/free",
            query: query,
            authorization: authorization
        )
        return (page.racecards ?? []).compactMap(RacingAPIMapping.race(from:))
    }

    // MARK: - Results

    public func results(day: RaceDay) async throws -> [RaceResult] {
        try requireCredentials()
        // The free results endpoint covers today and only today. Asking for
        // tomorrow is a programming error, not a data gap, so it says so plainly
        // rather than returning an empty list that would look like "no racing".
        guard day == .today else {
            throw APIError.badRequest(
                serverMessage: "The free tier only publishes results for today."
            )
        }
        let page: RacingAPIResultsPage = try await http.get(
            "/v1/results/today/free",
            authorization: authorization
        )
        return (page.results ?? []).compactMap(RacingAPIMapping.result(from:))
    }

    // MARK: - Form history (paid tiers)

    /// Attempts the Basic-tier per-horse history endpoint.
    ///
    /// This is the upgrade path in one method. On the free tier the first call
    /// gets a 403, capability narrows, and every later call short-circuits to
    /// `.tierUnavailable` without touching the network. Subscribe to Basic and it
    /// simply starts working — no call site changes, no rebuild of the rater.
    public func formHistory(horseID: String) async throws -> [HorseRun] {
        try requireCredentials()
        guard !formHistoryRefused else {
            throw APIError.tierUnavailable(feature: "Form history")
        }

        do {
            let page: RacingAPIResultsPage = try await http.get(
                "/v1/racecards/\(horseID)/results",
                authorization: authorization
            )
            detectedCapability.insert(.formHistory)
            return (page.results ?? []).compactMap {
                RacingAPIMapping.horseRun(from: $0, horseID: horseID)
            }
        } catch APIError.forbidden {
            formHistoryRefused = true
            detectedCapability.remove(.formHistory)
            throw APIError.tierUnavailable(feature: "Form history")
        } catch APIError.unauthorized {
            // Genuinely bad credentials, not a tier limit — let that surface as
            // itself so Settings can tell the user to check their details.
            throw APIError.unauthorized
        }
    }

    // MARK: -

    private func requireCredentials() throws {
        guard credentials.isComplete else {
            throw APIError.notConfigured(provider: "The Racing API")
        }
    }
}
