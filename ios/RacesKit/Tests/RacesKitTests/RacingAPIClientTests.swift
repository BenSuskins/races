import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RacesKit

final class RacingAPIClientTests: XCTestCase {

    private var transport: FakeHTTPTransport!

    override func setUp() {
        super.setUp()
        transport = FakeHTTPTransport()
    }

    private func makeClient(
        credentials: RacingAPICredentials = .init(username: "user", password: "pass")
    ) -> RacingAPIClient {
        RacingAPIClient(
            credentials: credentials,
            transport: transport,
            requestsPerSecond: 1000,
            retryPolicy: .none
        )
    }

    private func enqueueFixture(_ name: String) throws {
        transport.enqueue(.success(status: 200, body: try Fixture.data(name), headers: [:]))
    }

    private var lastPath: String? {
        transport.lastRequest?.url?.path
    }

    private var lastQuery: String? {
        transport.lastRequest?.url?.query
    }

    // MARK: - Courses

    func test_courses_callsTheFreeEndpointWithBasicAuth() async throws {
        try enqueueFixture("racingapi-courses.json")
        let client = makeClient()

        let courses = try await client.courses(regionCodes: ["gb"])

        XCTAssertEqual(courses.count, 5)
        XCTAssertEqual(lastPath, "/v1/courses")
        XCTAssertEqual(lastQuery, "region_codes=gb")
        XCTAssertEqual(transport.authorizationHeader(), "Basic dXNlcjpwYXNz")
    }

    func test_courses_sendsOneQueryItemPerRegion() async throws {
        try enqueueFixture("racingapi-courses.json")
        let client = makeClient()

        _ = try await client.courses(regionCodes: ["gb", "ire"])

        let query = try XCTUnwrap(lastQuery)
        XCTAssertTrue(query.contains("region_codes=gb"), query)
        XCTAssertTrue(query.contains("region_codes=ire"), query)
    }

    // MARK: - Racecards

    func test_racecards_callsTheFreePathForToday() async throws {
        try enqueueFixture("racingapi-racecards-free.json")
        let client = makeClient()

        let races = try await client.racecards(day: .today, regionCodes: ["gb"])

        XCTAssertEqual(races.count, 2)
        // The tier names are inverted: /racecards/free is what the free tier
        // reaches, and /racecards/basic is the paid, fuller payload.
        XCTAssertEqual(lastPath, "/v1/racecards/free")
        let query = try XCTUnwrap(lastQuery)
        XCTAssertTrue(query.contains("day=today"), query)
        XCTAssertTrue(query.contains("region_codes=gb"), query)
    }

    func test_racecards_tomorrowUsesTheTomorrowQueryValue() async throws {
        try enqueueFixture("racingapi-racecards-free.json")
        let client = makeClient()

        _ = try await client.racecards(day: .tomorrow, regionCodes: ["gb"])

        XCTAssertTrue(try XCTUnwrap(lastQuery).contains("day=tomorrow"))
    }

    func test_racecards_defaultRegionIsBritain() async throws {
        try enqueueFixture("racingapi-racecards-free.json")
        let client = makeClient()

        _ = try await client.racecards(day: .today)

        XCTAssertTrue(try XCTUnwrap(lastQuery).contains("region_codes=gb"))
    }

    // MARK: - Results

    func test_results_today() async throws {
        try enqueueFixture("racingapi-results-today-free.json")
        let client = makeClient()

        let results = try await client.results(day: .today)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(lastPath, "/v1/results/today/free")
    }

    /// The free results endpoint covers today and only today. Asking for tomorrow
    /// is a programming error, so it says so rather than returning an empty list
    /// that would read as "no racing".
    func test_results_tomorrowIsRejectedWithoutACall() async {
        let client = makeClient()

        do {
            _ = try await client.results(day: .tomorrow)
            XCTFail("Expected tomorrow's results to be refused")
        } catch let error as APIError {
            guard case .badRequest = error else {
                return XCTFail("Expected .badRequest, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertTrue(transport.requests.isEmpty, "no request should have been sent")
    }

    // MARK: - Credentials

    func test_missingCredentials_isReportedWithoutACall() async {
        let client = makeClient(credentials: .init(username: "", password: ""))

        do {
            _ = try await client.courses(regionCodes: ["gb"])
            XCTFail("Expected a not-configured failure")
        } catch let error as APIError {
            XCTAssertEqual(error, .notConfigured(provider: "The Racing API"))
            XCTAssertTrue(error.isExpectedLimitation, "an unconfigured provider is not a fault")
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertTrue(transport.requests.isEmpty)
    }

    func test_whitespaceOnlyCredentialsAreNotCredentials() {
        XCTAssertFalse(RacingAPICredentials(username: "  ", password: "pass").isComplete)
        XCTAssertFalse(RacingAPICredentials(username: "user", password: " ").isComplete)
        XCTAssertTrue(RacingAPICredentials(username: "user", password: "pass").isComplete)
    }

    // MARK: - Tier degradation

    func test_capability_startsAtTheFreeTier() async {
        let client = makeClient()
        let capability = await client.capability

        XCTAssertTrue(capability.contains(.racecards))
        XCTAssertTrue(capability.contains(.todayResults))
        XCTAssertFalse(capability.contains(.formHistory))
    }

    /// A 403 on the paid endpoint is the *expected* free-tier outcome, so it is
    /// translated into `.tierUnavailable` — which the rater treats as "drop those
    /// factors", not as a failure.
    func test_formHistory_forbiddenBecomesTierUnavailable() async throws {
        transport.enqueueStatus(403, body: "Forbidden")
        let client = makeClient()

        do {
            _ = try await client.formHistory(horseID: "hrs_1")
            XCTFail("Expected the free tier to be refused")
        } catch let error as APIError {
            XCTAssertEqual(error, .tierUnavailable(feature: "Form history"))
            XCTAssertTrue(error.isExpectedLimitation)
        }

        let capability = await client.capability
        XCTAssertFalse(capability.contains(.formHistory))
    }

    /// Twenty runners in a race would otherwise mean twenty 403s, each burning a
    /// rate-limit slot a useful request could have had.
    func test_formHistory_stopsAskingOnceRefused() async throws {
        transport.enqueueStatus(403, body: "Forbidden")
        let client = makeClient()

        _ = try? await client.formHistory(horseID: "hrs_1")
        _ = try? await client.formHistory(horseID: "hrs_2")
        _ = try? await client.formHistory(horseID: "hrs_3")

        XCTAssertEqual(transport.requests.count, 1, "the refusal should be remembered")
    }

    /// Bad credentials are not a tier limit, and must not be quietly reclassified
    /// as one — Settings needs to tell the user to check their details.
    func test_formHistory_unauthorizedIsNotMistakenForATierLimit() async {
        transport.enqueueStatus(401, body: "Unauthorized")
        let client = makeClient()

        do {
            _ = try await client.formHistory(horseID: "hrs_1")
            XCTFail("Expected an authorization failure")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    /// The upgrade path, exercised. On a paid tier the same call succeeds, the
    /// capability widens, and the deep-form factors light up with no change at any
    /// call site.
    func test_formHistory_succeedsAndWidensCapabilityOnAPaidTier() async throws {
        try enqueueFixture("racingapi-horse-results.json")
        let client = makeClient()

        let runs = try await client.formHistory(horseID: "hrs_1")

        XCTAssertEqual(lastPath, "/v1/racecards/hrs_1/results")
        // Three races in the fixture, but one has no run by this horse.
        XCTAssertEqual(runs.count, 2)

        let york = try XCTUnwrap(runs.first { $0.raceID == "rac_900" })
        XCTAssertEqual(york.position, .finished(1))
        XCTAssertEqual(york.courseName, "York")
        XCTAssertEqual(york.going, .good)
        XCTAssertEqual(york.raceClass, 1)
        XCTAssertEqual(york.distance?.furlongs, 10.4)
        XCTAssertEqual(york.fieldSize, 2)
        XCTAssertEqual(york.startingPriceDecimal, 3.5)
        XCTAssertEqual(york.racingPostRating, 118)
        XCTAssertEqual(york.topspeedRating, 105)
        XCTAssertEqual(york.beatenLengths, 0)
        XCTAssertEqual(york.comment, "travelled strongly, led 1f out")

        let goodwood = try XCTUnwrap(runs.first { $0.raceID == "rac_901" })
        XCTAssertEqual(goodwood.position, .finished(4))
        XCTAssertEqual(goodwood.going, .goodToSoft)
        XCTAssertEqual(goodwood.overallBeatenLengths, 6.75)

        let capability = await client.capability
        XCTAssertTrue(capability.contains(.formHistory), "a successful call should widen the tier")
    }

    // MARK: - Capability copy

    func test_capabilitySummary_readsAsInformationNotAsAnError() {
        XCTAssertTrue(ProviderCapability.free.summary.contains("isn't on your plan"))
        XCTAssertTrue(ProviderCapability.basic.summary.contains("Full form history"))
    }
}
