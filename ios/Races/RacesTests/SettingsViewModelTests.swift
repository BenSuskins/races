import XCTest
@testable import Races
import RacesKit

final class SettingsViewModelTests: XCTestCase {

    @MainActor
    private func makeEnvironment(
        _ initial: [CredentialSlot: String] = [:],
        provider: FakeRacingDataProvider = FakeRacingDataProvider()
    ) -> (AppEnvironment, InMemoryCredentialsStore) {
        let store = InMemoryCredentialsStore(initial)
        let environment = AppEnvironment(credentials: store, makeRacingProvider: { _ in provider })
        return (environment, store)
    }

    @MainActor
    func test_theUsernameIsShownBackButThePasswordIsNot() {
        let (environment, _) = makeEnvironment([
            .racingAPIUsername: "ben",
            .racingAPIPassword: "secret",
        ])

        let model = SettingsViewModel(environment: environment)

        XCTAssertEqual(model.username, "ben")
        XCTAssertEqual(model.password, "", "A populated field would imply resubmitting it is safe")
    }

    @MainActor
    func test_saveRequiresBothFields() {
        let (environment, _) = makeEnvironment()
        let model = SettingsViewModel(environment: environment)

        XCTAssertFalse(model.canSave)
        model.username = "ben"
        XCTAssertFalse(model.canSave, "A username alone would 401")
        model.password = "secret"
        XCTAssertTrue(model.canSave)
    }

    @MainActor
    func test_aWhitespaceOnlyUsernameCannotBeSaved() {
        let (environment, _) = makeEnvironment()
        let model = SettingsViewModel(environment: environment)
        model.username = "   "
        model.password = "secret"

        XCTAssertFalse(model.canSave)
    }

    @MainActor
    func test_savingTrimsTheUsernameAndClearsTheDraftPassword() {
        let (environment, store) = makeEnvironment()
        let model = SettingsViewModel(environment: environment)
        model.username = "  ben  "
        model.password = "secret"

        model.save()

        XCTAssertEqual(store.slots[.racingAPIUsername], "ben")
        XCTAssertEqual(store.slots[.racingAPIPassword], "secret")
        XCTAssertEqual(model.password, "", "The draft must not outlive the write")
        XCTAssertNil(model.saveError)
        XCTAssertTrue(model.isConfigured)
    }

    @MainActor
    func test_aKeychainFailureOnSaveIsSurfaced() {
        let store = InMemoryCredentialsStore()
        let environment = AppEnvironment(credentials: store, makeRacingProvider: { _ in
            FakeRacingDataProvider()
        })
        store.failure = APIError.decoding

        let model = SettingsViewModel(environment: environment)
        model.username = "ben"
        model.password = "secret"
        model.save()

        XCTAssertNotNil(model.saveError)
    }

    @MainActor
    func test_testConnectionReportsTheCourseCountAndTheDetectedTier() async {
        let provider = FakeRacingDataProvider(
            courses: .success([.fixture(id: "c1"), .fixture(id: "c2")]),
            capability: .free)
        let (environment, _) = makeEnvironment([
            .racingAPIUsername: "ben",
            .racingAPIPassword: "secret",
        ], provider: provider)
        let model = SettingsViewModel(environment: environment)

        await model.test()

        XCTAssertEqual(model.testResult, .succeeded(courseCount: 2, capability: .free))
    }

    @MainActor
    func test_testConnectionSurfacesBadCredentials() async {
        let provider = FakeRacingDataProvider(courses: .failure(.unauthorized))
        let (environment, _) = makeEnvironment([
            .racingAPIUsername: "ben",
            .racingAPIPassword: "wrong",
        ], provider: provider)
        let model = SettingsViewModel(environment: environment)

        await model.test()

        XCTAssertEqual(model.testResult, .failed(.unauthorized))
    }

    @MainActor
    func test_savingNewCredentialsInvalidatesAnEarlierTestResult() async {
        let provider = FakeRacingDataProvider(courses: .success([.fixture()]))
        let (environment, _) = makeEnvironment([
            .racingAPIUsername: "ben",
            .racingAPIPassword: "secret",
        ], provider: provider)
        let model = SettingsViewModel(environment: environment)

        await model.test()
        XCTAssertNotEqual(model.testResult, .untested)

        model.password = "different"
        model.save()

        // A green tick against credentials that have since changed is a lie.
        XCTAssertEqual(model.testResult, .untested)
    }

    @MainActor
    func test_clearingResetsEverything() {
        let (environment, store) = makeEnvironment([
            .racingAPIUsername: "ben",
            .racingAPIPassword: "secret",
        ])
        let model = SettingsViewModel(environment: environment)

        model.clear()

        XCTAssertEqual(model.username, "")
        XCTAssertEqual(model.password, "")
        XCTAssertFalse(model.isConfigured)
        XCTAssertTrue(store.slots.isEmpty)
    }
}
