import XCTest
@testable import Races
import RacesKit

/// Every test is `@MainActor async`; see the gotcha in CLAUDE.md.
final class SettingsViewModelTests: XCTestCase {

    @MainActor
    private func makeModel(
        _ credentials: InMemoryCredentialsStore,
        server: FakeRacesServer = FakeRacesServer(),
        history: LegacyHistory? = nil
    ) throws -> (SettingsViewModel, AppEnvironment) {
        let environment = AppEnvironment(
            credentials: credentials,
            store: RacesStore(documents: InMemoryDocumentStore()),
            history: try history ?? temporaryHistory(),
            makeServer: { _ in server })
        return (SettingsViewModel(environment: environment, deviceName: "Test iPhone"), environment)
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
    func test_uploadingHistorySendsTheDocumentsAndRemembersIt() async throws {
        let history = try temporaryHistory(documents: [LegacyHistory.tips: #"{"schemaVersion":1,"payload":{"storage":{}}}"#])
        let server = FakeRacesServer(importSummary: .success(.fixture(tipsAdded: 3)))
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let environment = AppEnvironment(
            credentials: InMemoryCredentialsStore([.serverToken: "t"]),
            store: RacesStore(documents: InMemoryDocumentStore()),
            history: history,
            makeServer: { _ in server })
        let model = SettingsViewModel(environment: environment, deviceName: "Test iPhone", now: { moment })
        XCTAssertTrue(model.hasHistoryToUpload)

        await model.uploadHistory()

        XCTAssertEqual(server.uploads.count, 1)
        XCTAssertEqual(server.uploads.first?.device, "Test iPhone")
        XCTAssertNotNil(server.uploads.first?.tips)
        XCTAssertEqual(model.uploadResult, .succeeded(.fixture(tipsAdded: 3)))
        XCTAssertEqual(model.historyUploadedAt, moment)
    }

    @MainActor
    func test_aFailedUploadIsNotMarkedAsDone() async throws {
        let history = try temporaryHistory(documents: [LegacyHistory.archive: "{}"])
        let server = FakeRacesServer(importSummary: .failure(.unauthorized))
        let (model, _) = try makeModel(InMemoryCredentialsStore([.serverToken: "t"]), server: server, history: history)

        await model.uploadHistory()

        XCTAssertEqual(model.uploadResult, .failed(.unauthorized))
        XCTAssertNil(model.historyUploadedAt)
        XCTAssertNil(history.uploadedAt)
    }

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
