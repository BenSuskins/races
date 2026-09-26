import XCTest
@testable import Races
import RacesKit

/// Every test is `@MainActor async`; see the gotcha in CLAUDE.md.
final class SettingsViewModelTests: XCTestCase {

    @MainActor
    private func makeModel(
        _ credentials: InMemoryCredentialsStore,
        server: FakeRacesServer = FakeRacesServer()
    ) throws -> (SettingsViewModel, AppEnvironment) {
        let environment = AppEnvironment(
            credentials: credentials,
            store: RacesStore(documents: InMemoryDocumentStore()),
            makeServer: { _ in server })
        return (SettingsViewModel(environment: environment), environment)
    }

    @MainActor
    func test_savingATokenConfiguresTheServerAndClearsTheOldProviderSecrets() async throws {
        let credentials = InMemoryCredentialsStore([
            .racingAPIUsername: "ben", .racingAPIPassword: "old", .betfairPassword: "old",
        ])
        let (model, environment) = try makeModel(credentials)
        XCTAssertFalse(model.isConfigured)

        model.token = "  secret-token  "
        model.save()

        XCTAssertTrue(model.isConfigured)
        XCTAssertNotNil(environment.server)
        XCTAssertEqual(credentials.slots[.serverToken], "secret-token")
        XCTAssertEqual(model.token, "", "the field is cleared once saved")
        XCTAssertNil(credentials.slots[.racingAPIPassword])
        XCTAssertNil(credentials.slots[.betfairPassword])
    }

    @MainActor
    func test_aBlankAddressMeansTheDefault() async throws {
        let credentials = InMemoryCredentialsStore([.serverURL: "https://old.example"])
        let (model, environment) = try makeModel(credentials)
        XCTAssertEqual(model.serverURL, "https://old.example")

        model.serverURL = " "
        model.token = "t"
        model.save()

        XCTAssertNil(credentials.slots[.serverURL])
        XCTAssertEqual(environment.configuration?.baseURL, ServerConfiguration.defaultBaseURL)
    }

    @MainActor
    func test_changingOnlyTheAddressKeepsTheToken() async throws {
        let credentials = InMemoryCredentialsStore([.serverToken: "kept"])
        let (model, _) = try makeModel(credentials)
        XCTAssertTrue(model.canSave)

        model.serverURL = "http://192.168.0.202:8790"
        model.save()

        XCTAssertEqual(credentials.slots[.serverToken], "kept")
        XCTAssertEqual(credentials.slots[.serverURL], "http://192.168.0.202:8790")
    }

    @MainActor
    func test_testReportsTheServersStatus() async throws {
        let server = FakeRacesServer(status: .success(.fixture(betfairConfigured: false)))
        let (model, _) = try makeModel(InMemoryCredentialsStore([.serverToken: "t"]), server: server)

        await model.test()

        guard case .succeeded(let status) = model.testResult else {
            return XCTFail("expected success, got \(model.testResult)")
        }
        XCTAssertFalse(status.betfair.configured)
    }

    @MainActor
    func test_testWithoutAServerSaysNotConfigured() async throws {
        let (model, _) = try makeModel(InMemoryCredentialsStore())

        await model.test()

        XCTAssertEqual(model.testResult, .failed(.notConfigured(provider: "The Races server")))
    }

    @MainActor
    @MainActor
    func test_clearRemovesEverything() async throws {
        let credentials = InMemoryCredentialsStore([.serverToken: "t", .serverURL: "https://x.example"])
        let (model, environment) = try makeModel(credentials)

        model.clear()

        XCTAssertTrue(credentials.slots.isEmpty)
        XCTAssertNil(environment.server)
        XCTAssertEqual(model.serverURL, "")
    }
}
