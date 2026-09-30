import XCTest
@testable import Races
import RacesKit

/// `AppEnvironment` is the only place that decides whether the server exists.
final class AppEnvironmentTests: XCTestCase {

    @MainActor
    private func makeEnvironment(
        _ store: InMemoryCredentialsStore,
        built: CallCounter = CallCounter()
    ) throws -> AppEnvironment {
        AppEnvironment(
            credentials: store,
            store: RacesStore(documents: InMemoryDocumentStore()),
            makeServer: { _ in
                built.increment()
                return FakeRacesServer()
            })
    }

    @MainActor
    func test_aTokenMakesTheServerAvailable() async throws {
        let environment = try makeEnvironment(InMemoryCredentialsStore([.serverToken: "token"]))

        XCTAssertNotNil(environment.server)
        XCTAssertNil(environment.unavailabilityReason)
        XCTAssertEqual(environment.configuration?.baseURL, ServerConfiguration.defaultBaseURL)
    }

    @MainActor
    func test_noTokenIsNotConfiguredRatherThanAnError() async throws {
        let environment = try makeEnvironment(InMemoryCredentialsStore([.serverURL: "https://example.com"]))

        XCTAssertNil(environment.server)
        XCTAssertEqual(environment.unavailabilityReason, .notConfigured(provider: "The Races server"))
        XCTAssertTrue(environment.unavailabilityReason?.isExpectedLimitation == true)
        XCTAssertNil(environment.credentialsFailure)
    }

    @MainActor
    func test_aBrokenKeychainIsReportedAsItself() async throws {
        let store = InMemoryCredentialsStore([.serverToken: "token"], failure: APIError.forbidden)
        let environment = try makeEnvironment(store)

        XCTAssertNil(environment.server)
        XCTAssertEqual(environment.credentialsFailure, .forbidden)
        XCTAssertEqual(environment.unavailabilityReason, .forbidden)
    }

    /// The link is long-lived and its server is swapped in place, so a screen
    /// built before the token was entered sees the server without a relaunch.
    @MainActor
    func test_writingATokenSwapsTheServerIntoTheSameLink() async throws {
        let built = CallCounter()
        let environment = try makeEnvironment(InMemoryCredentialsStore(), built: built)
        let link = environment.link
        XCTAssertNil(link.server)

        try environment.write("token", to: .serverToken)

        XCTAssertTrue(environment.link === link)
        XCTAssertNotNil(link.server)
        XCTAssertEqual(built.count, 1)
        XCTAssertTrue(environment.hasAnyStoredCredential)
    }

    @MainActor
    func test_removingCredentialsTakesTheServerAway() async throws {
        let environment = try makeEnvironment(InMemoryCredentialsStore([.serverToken: "token"]))

        try environment.removeAllCredentials()

        XCTAssertNil(environment.link.server)
        XCTAssertFalse(environment.hasAnyStoredCredential)
    }

    @MainActor
    func test_aLinkWithNoServerThrowsItsReason() async throws {
        let link = ServerLink(server: nil, unavailable: .forbidden)
        XCTAssertThrowsError(try link.require()) { error in
            XCTAssertEqual(error as? APIError, .forbidden)
        }
    }
}
