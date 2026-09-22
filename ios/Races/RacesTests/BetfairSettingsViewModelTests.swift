import XCTest
@testable import Races
import RacesKit

/// Every test here is `@MainActor async`, and the `async` is load-bearing even
/// where nothing is awaited — see the gotcha in CLAUDE.md.
final class BetfairSettingsViewModelTests: XCTestCase {

    private static let configured: [CredentialSlot: String] = [
        .betfairAppKey: "appkey",
        .betfairUsername: "ben",
        .betfairPassword: "secret",
    ]

    @MainActor
    private func makeEnvironment(
        _ initial: [CredentialSlot: String] = [:],
        market: FakeMarketDataProvider = FakeMarketDataProvider()
    ) -> (AppEnvironment, InMemoryCredentialsStore) {
        let store = InMemoryCredentialsStore(initial)
        let environment = AppEnvironment(
            credentials: store,
            makeRacingProvider: { _ in FakeRacingDataProvider() },
            makeMarketProvider: { _ in market })
        return (environment, store)
    }

    @MainActor
    func test_theAppKeyAndUsernameAreShownBackButThePasswordIsNot() async {
        let (environment, _) = makeEnvironment(Self.configured)

        let model = BetfairSettingsViewModel(environment: environment)

        // A mistyped app key is invisible unless it is shown back.
        XCTAssertEqual(model.appKey, "appkey")
        XCTAssertEqual(model.username, "ben")
        XCTAssertEqual(model.password, "")
        XCTAssertTrue(model.isConfigured)
    }

    @MainActor
    func test_allThreeFieldsAreRequiredToSave() async {
        let (environment, _) = makeEnvironment()
        let model = BetfairSettingsViewModel(environment: environment)

        model.appKey = "appkey"
        XCTAssertFalse(model.canSave)
        model.username = "ben"
        XCTAssertFalse(model.canSave)
        model.password = "secret"
        XCTAssertTrue(model.canSave)
    }

    @MainActor
    func test_savingTrimsAndConfiguresTheMarketProvider() async {
        let (environment, store) = makeEnvironment()
        let model = BetfairSettingsViewModel(environment: environment)

        model.appKey = "  appkey "
        model.username = " ben "
        model.password = "secret"
        model.save()

        XCTAssertEqual(store.slots[.betfairAppKey], "appkey")
        XCTAssertEqual(store.slots[.betfairUsername], "ben")
        XCTAssertEqual(store.slots[.betfairPassword], "secret")
        XCTAssertEqual(model.password, "")
        // Entering credentials has to take effect without a relaunch.
        XCTAssertNotNil(environment.marketProvider)
        XCTAssertTrue(environment.marketLoader.isConfigured)
    }

    @MainActor
    func test_removingBetfairLeavesTheRacingAPIAlone() async {
        // Losing the racecard as well would leave the app with nothing to show,
        // which is not what "remove Betfair" means.
        let (environment, store) = makeEnvironment(
            Self.configured.merging([
                .racingAPIUsername: "ben",
                .racingAPIPassword: "secret",
            ], uniquingKeysWith: { current, _ in current }))
        let model = BetfairSettingsViewModel(environment: environment)

        model.clear()

        XCTAssertNil(store.slots[.betfairAppKey])
        XCTAssertNil(store.slots[.betfairPassword])
        XCTAssertNil(environment.marketProvider)
        XCTAssertNotNil(environment.racingProvider)
        XCTAssertFalse(environment.marketLoader.isConfigured)
    }

    @MainActor
    func test_testReportsTheMarketCount() async {
        let market = FakeMarketDataProvider(
            markets: .success([
                .fixture(startTime: Date(timeIntervalSince1970: 1_000_000), runners: [])
            ]))
        let (environment, _) = makeEnvironment(Self.configured, market: market)
        let model = BetfairSettingsViewModel(environment: environment)

        await model.test()

        XCTAssertEqual(model.testResult, .succeeded(marketCount: 1))
    }

    @MainActor
    func test_aLoginRefusalKeepsBetfairsOwnCodeAndItsClassification() async {
        // The three classes need three different instructions, and only one of
        // them is answered by re-typing a password. Mapping them all to
        // `.unauthorized` would send the user round in circles.
        let cases: [(code: String, isBadCredentials: Bool, requiresUserAction: Bool, requiresCert: Bool)] = [
            ("INVALID_USERNAME_OR_PASSWORD", true, false, false),
            ("SECURITY_QUESTION_REQUIRED", false, true, false),
            ("CERT_AUTH_REQUIRED", false, false, true),
        ]

        for expected in cases {
            let market = FakeMarketDataProvider(
                markets: .failure(BetfairLoginFailure(code: expected.code)))
            let (environment, _) = makeEnvironment(Self.configured, market: market)
            let model = BetfairSettingsViewModel(environment: environment)

            await model.test()

            guard case .refused(let failure) = model.testResult else {
                XCTFail("Expected a refusal for \(expected.code), got \(model.testResult)")
                continue
            }
            XCTAssertEqual(failure.code, expected.code)
            XCTAssertEqual(failure.isBadCredentials, expected.isBadCredentials)
            XCTAssertEqual(failure.requiresUserAction, expected.requiresUserAction)
            XCTAssertEqual(failure.requiresCertificateLogin, expected.requiresCert)
        }
    }

    @MainActor
    func test_anUnconfiguredProviderIsReportedAsNotConfigured() async {
        let (environment, _) = makeEnvironment()
        let model = BetfairSettingsViewModel(environment: environment)

        await model.test()

        XCTAssertEqual(model.testResult, .failed(.notConfigured(provider: "Betfair")))
    }

    @MainActor
    func test_halfEnteredCredentialsAreNotConfigured() async {
        // Same rule as the Racing API: an app key with no password would 401 and
        // the user would be told their credentials are wrong rather than that a
        // field is blank.
        let (environment, _) = makeEnvironment([
            .betfairAppKey: "appkey",
            .betfairUsername: "ben",
        ])
        let model = BetfairSettingsViewModel(environment: environment)

        XCTAssertFalse(model.isConfigured)
        XCTAssertNil(environment.marketProvider)
    }

    @MainActor
    func test_savingInvalidatesAnEarlierTestResult() async {
        let market = FakeMarketDataProvider(markets: .success([]))
        let (environment, _) = makeEnvironment(Self.configured, market: market)
        let model = BetfairSettingsViewModel(environment: environment)
        await model.test()
        XCTAssertEqual(model.testResult, .succeeded(marketCount: 0))

        model.password = "different"
        model.save()

        // A result that outlived the credentials it was obtained with would
        // report a connection that no longer exists.
        XCTAssertEqual(model.testResult, .untested)
    }
}
