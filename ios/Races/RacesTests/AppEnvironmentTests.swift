import XCTest
@testable import Races
import RacesKit

/// Every test here is `@MainActor async`, and the `async` is load-bearing even
/// where nothing is awaited: a synchronous `@MainActor` test method never runs its
/// body, reports `failed` in 0.000s with no message, and stops the rest of the
/// suite from reporting at all. See the gotcha in CLAUDE.md.
final class AppEnvironmentTests: XCTestCase {

    @MainActor
    func test_completeCredentialsProduceAProvider() async {
        let store = InMemoryCredentialsStore([
            .racingAPIUsername: "ben",
            .racingAPIPassword: "secret",
        ])

        let environment = AppEnvironment(credentials: store, makeRacingProvider: { _ in
            FakeRacingDataProvider()
        })

        XCTAssertNotNil(environment.racingProvider)
        XCTAssertNil(environment.unavailabilityReason)
    }

    @MainActor
    func test_halfConfiguredIsNotConfigured() async {
        // A username with no password would 401, and the user would be told their
        // credentials are wrong rather than that a field is blank.
        let store = InMemoryCredentialsStore([.racingAPIUsername: "ben"])

        let environment = AppEnvironment(credentials: store, makeRacingProvider: { _ in
            FakeRacingDataProvider()
        })

        XCTAssertNil(environment.racingProvider)
        XCTAssertEqual(
            environment.unavailabilityReason,
            .notConfigured(provider: "The Racing API"))
    }

    @MainActor
    func test_aBrokenKeychainIsNotReportedAsMissingCredentials() async {
        let store = InMemoryCredentialsStore(failure: APIError.decoding)

        let environment = AppEnvironment(credentials: store, makeRacingProvider: { _ in
            FakeRacingDataProvider()
        })

        // The difference matters: "add your key" is wrong advice when the key is
        // already there and unreadable, and the user has no way to discover that.
        XCTAssertNotNil(environment.credentialsFailure)
        XCTAssertNotEqual(
            environment.unavailabilityReason,
            .notConfigured(provider: "The Racing API"))
    }

    @MainActor
    func test_writingCredentialsRebuildsTheProviderWithoutARelaunch() async throws {
        let store = InMemoryCredentialsStore()
        let builds = CallCounter()
        let environment = AppEnvironment(credentials: store, makeRacingProvider: { _ in
            builds.increment()
            return FakeRacingDataProvider()
        })

        XCTAssertNil(environment.racingProvider)
        XCTAssertEqual(builds.count, 0)

        try environment.write("ben", to: .racingAPIUsername)
        XCTAssertNil(environment.racingProvider, "Still half-configured")

        try environment.write("secret", to: .racingAPIPassword)
        XCTAssertNotNil(environment.racingProvider)
        XCTAssertEqual(builds.count, 1)
    }

    @MainActor
    func test_clearingCredentialsDropsTheProvider() async throws {
        let store = InMemoryCredentialsStore([
            .racingAPIUsername: "ben",
            .racingAPIPassword: "secret",
        ])
        let environment = AppEnvironment(credentials: store, makeRacingProvider: { _ in
            FakeRacingDataProvider()
        })
        XCTAssertNotNil(environment.racingProvider)

        try environment.removeAllCredentials()

        XCTAssertNil(environment.racingProvider)
        XCTAssertTrue(store.slots.isEmpty)
    }
}
