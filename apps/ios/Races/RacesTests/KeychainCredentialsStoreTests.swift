import XCTest
import Security
@testable import Races
import RacesKit

/// Records every call and returns scripted statuses, so the query construction
/// and status mapping can be tested without a signed container. The real
/// Keychain refuses an unsigned test bundle with `errSecMissingEntitlement`.
private final class FakeKeychain: KeychainOperating, @unchecked Sendable {
    private let lock = NSLock()

    private(set) var copyQueries: [[String: Any]] = []
    private(set) var addAttributes: [[String: Any]] = []
    private(set) var updateQueries: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    var copyResult: (status: OSStatus, item: CFTypeRef?) = (errSecItemNotFound, nil)
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecItemNotFound
    var deleteStatus: OSStatus = errSecSuccess

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        lock.lock(); defer { lock.unlock() }
        copyQueries.append(query)
        return copyResult
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        addAttributes.append(attributes)
        return addStatus
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        updateQueries.append(query)
        return updateStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        deleteQueries.append(query)
        return deleteStatus
    }
}

final class KeychainCredentialsStoreTests: XCTestCase {

    private let service = "test.races.providers"

    private func makeStore(_ keychain: FakeKeychain) -> KeychainCredentialsStore {
        KeychainCredentialsStore(service: service, keychain: keychain)
    }

    // MARK: - Reading

    func test_read_returnsStoredString() throws {
        let keychain = FakeKeychain()
        keychain.copyResult = (errSecSuccess, Data("secret".utf8) as NSData)

        let value = try makeStore(keychain).read(.racingAPIPassword)

        XCTAssertEqual(value, "secret")
    }

    /// Absent is `nil`, not an error. A fresh install hits this on every slot.
    func test_read_missingItemIsNil() throws {
        let keychain = FakeKeychain()
        keychain.copyResult = (errSecItemNotFound, nil)

        XCTAssertNil(try makeStore(keychain).read(.betfairAppKey))
    }

    func test_read_otherFailuresThrow() {
        let keychain = FakeKeychain()
        keychain.copyResult = (errSecMissingEntitlement, nil)

        XCTAssertThrowsError(try makeStore(keychain).read(.betfairAppKey)) { error in
            XCTAssertEqual(error as? KeychainError, .status(errSecMissingEntitlement))
            XCTAssertTrue((error as? KeychainError)?.isMissingEntitlement ?? false)
        }
    }

    /// One slot must never return another's value, so the query has to pin both
    /// the service and the account.
    func test_read_queriesTheRightAccount() throws {
        let keychain = FakeKeychain()
        _ = try makeStore(keychain).read(.betfairUsername)

        let query = try XCTUnwrap(keychain.copyQueries.first)
        XCTAssertEqual(query[kSecAttrService as String] as? String, service)
        XCTAssertEqual(
            query[kSecAttrAccount as String] as? String,
            CredentialSlot.betfairUsername.rawValue)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
    }

    // MARK: - Writing

    /// Update first. `SecItemAdd` on an existing account returns
    /// `errSecDuplicateItem`, and overwriting is the common case — a user
    /// correcting a typo, not creating something new.
    func test_write_updatesExistingItemWithoutAdding() throws {
        let keychain = FakeKeychain()
        keychain.updateStatus = errSecSuccess

        try makeStore(keychain).write("new", to: .racingAPIUsername)

        XCTAssertEqual(keychain.updateQueries.count, 1)
        XCTAssertTrue(keychain.addAttributes.isEmpty)
    }

    func test_write_addsWhenAbsent() throws {
        let keychain = FakeKeychain()
        keychain.updateStatus = errSecItemNotFound

        try makeStore(keychain).write("new", to: .racingAPIUsername)

        let attributes = try XCTUnwrap(keychain.addAttributes.first)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data("new".utf8))
    }

    /// Background reconciliation can fire while the phone is locked and still
    /// needs these credentials, so `WhenUnlocked` would break it.
    /// `ThisDeviceOnly` keeps them out of an iCloud backup.
    func test_write_usesAfterFirstUnlockThisDeviceOnly() throws {
        let keychain = FakeKeychain()
        keychain.updateStatus = errSecItemNotFound

        try makeStore(keychain).write("new", to: .betfairPassword)

        let attributes = try XCTUnwrap(keychain.addAttributes.first)
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    /// Clearing a field in Settings has to remove the item. Storing an empty
    /// string instead would leave the provider looking configured.
    func test_write_nilOrEmptyDeletes() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)

        try store.write(nil, to: .racingAPIPassword)
        try store.write("", to: .betfairPassword)

        XCTAssertEqual(keychain.deleteQueries.count, 2)
        XCTAssertTrue(keychain.addAttributes.isEmpty)
        XCTAssertTrue(keychain.updateQueries.isEmpty)
    }

    func test_write_failureThrows() {
        let keychain = FakeKeychain()
        keychain.updateStatus = errSecItemNotFound
        keychain.addStatus = errSecIO

        XCTAssertThrowsError(try makeStore(keychain).write("x", to: .racingAPIUsername)) {
            XCTAssertEqual($0 as? KeychainError, .status(errSecIO))
        }
    }

    // MARK: - Removing

    func test_removeAll_deletesEverySlot() throws {
        let keychain = FakeKeychain()

        try makeStore(keychain).removeAll()

        XCTAssertEqual(keychain.deleteQueries.count, CredentialSlot.allCases.count)
        let accounts = keychain.deleteQueries.compactMap { $0[kSecAttrAccount as String] as? String }
        XCTAssertEqual(Set(accounts), Set(CredentialSlot.allCases.map(\.rawValue)))
    }

    /// Deleting something that isn't there is the desired end state.
    func test_delete_itemNotFoundIsNotAFailure() throws {
        let keychain = FakeKeychain()
        keychain.deleteStatus = errSecItemNotFound

        XCTAssertNoThrow(try makeStore(keychain).removeAll())
    }

    // MARK: - Through the kit's reader

    /// The point of the whole seam: the kit assembles a `ProviderConfiguration`
    /// from the app's Keychain store without knowing what a Keychain is.
    func test_providerConfiguration_readsThroughTheStore() throws {
        let keychain = FakeKeychain()
        keychain.copyResult = (errSecSuccess, Data("filled".utf8) as NSData)

        let configuration = try ProviderConfiguration(reading: makeStore(keychain))

        XCTAssertEqual(configuration.racingAPI?.username, "filled")
        XCTAssertEqual(configuration.betfair?.appKey, "filled")
    }
}
