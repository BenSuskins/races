import XCTest
@testable import RacesKit

/// An in-memory `CredentialsStoring`, standing in for the app's Keychain store.
/// `@unchecked Sendable` with a lock: the protocol is `Sendable` because the
/// real implementation is reachable from any isolation domain.
private final class FakeCredentialsStore: CredentialsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialSlot: String] = [:]

    /// When set, every read throws it — the Keychain genuinely can fail.
    var readError: (any Error)?

    init(_ values: [CredentialSlot: String] = [:]) {
        self.values = values
    }

    func read(_ slot: CredentialSlot) throws -> String? {
        if let readError { throw readError }
        lock.lock(); defer { lock.unlock() }
        return values[slot]
    }

    func write(_ value: String?, to slot: CredentialSlot) throws {
        lock.lock(); defer { lock.unlock() }
        if let value {
            values[slot] = value
        } else {
            values.removeValue(forKey: slot)
        }
    }

    func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }
}

private struct StoreFailure: Error {}

final class CredentialsStoringTests: XCTestCase {

    // MARK: - Nothing configured

    /// First run. Not an error: the app has to be usable before any credentials
    /// are entered, or Settings can never be reached to enter them.
    func test_emptyStore_configuresNothing() throws {
        let configuration = try ProviderConfiguration(reading: FakeCredentialsStore())

        XCTAssertTrue(configuration.isEmpty)
        XCTAssertNil(configuration.racingAPI)
        XCTAssertNil(configuration.betfair)
    }

    // MARK: - Half-configured is not configured

    /// The rule worth having a test for. A username with no password would build
    /// a request that 401s, and the user would be told their credentials are
    /// wrong rather than that a field is blank.
    func test_racingAPI_withoutPassword_isNotConfigured() throws {
        let store = FakeCredentialsStore([.racingAPIUsername: "someone"])

        let configuration = try ProviderConfiguration(reading: store)

        XCTAssertNil(configuration.racingAPI)
    }

    func test_racingAPI_withoutUsername_isNotConfigured() throws {
        let store = FakeCredentialsStore([.racingAPIPassword: "secret"])

        XCTAssertNil(try ProviderConfiguration(reading: store).racingAPI)
    }

    /// Betfair needs all three. An app key with no login is the easy mistake,
    /// since the key arrives separately from the account it belongs to.
    func test_betfair_needsAllThreeFields() throws {
        let partial = FakeCredentialsStore([
            .betfairAppKey: "key",
            .betfairUsername: "someone",
        ])

        XCTAssertNil(try ProviderConfiguration(reading: partial).betfair)

        try partial.write("secret", to: .betfairPassword)

        XCTAssertEqual(
            try ProviderConfiguration(reading: partial).betfair,
            ProviderConfiguration.Betfair(
                appKey: "key", username: "someone", password: "secret"))
    }

    // MARK: - Whitespace

    /// A field the user cleared by selecting the text and typing a space is
    /// empty, and a value pasted from a password manager routinely carries a
    /// trailing newline.
    func test_blankAndWhitespaceValuesCountAsAbsent() throws {
        let store = FakeCredentialsStore([
            .racingAPIUsername: "  someone\n",
            .racingAPIPassword: "   ",
        ])

        XCTAssertNil(try ProviderConfiguration(reading: store).racingAPI)

        try store.write("secret", to: .racingAPIPassword)

        XCTAssertEqual(try ProviderConfiguration(reading: store).racingAPI?.username, "someone")
    }

    // MARK: - One provider without the other

    /// Both absences are normal states. Betfair unconfigured means the rater
    /// falls back to form-only, which has to work.
    func test_providersAreIndependent() throws {
        let racingOnly = FakeCredentialsStore([
            .racingAPIUsername: "someone",
            .racingAPIPassword: "secret",
        ])

        let configuration = try ProviderConfiguration(reading: racingOnly)

        XCTAssertNotNil(configuration.racingAPI)
        XCTAssertNil(configuration.betfair)
        XCTAssertFalse(configuration.isEmpty)
    }

    // MARK: - Failure

    /// A failing store propagates rather than reading as "not configured" —
    /// otherwise a locked Keychain would silently look like a fresh install and
    /// Settings would invite the user to type it all in again.
    func test_readFailurePropagates() {
        let store = FakeCredentialsStore([.racingAPIUsername: "someone"])
        store.readError = StoreFailure()

        XCTAssertThrowsError(try ProviderConfiguration(reading: store))
    }

    // MARK: - Slots

    func test_onlyPasswordSlotsAreSecret() {
        let secret = CredentialSlot.allCases.filter(\.isSecret)

        XCTAssertEqual(Set(secret), [.racingAPIPassword, .betfairPassword])
    }
}
