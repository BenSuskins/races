import Foundation
import Security
import RacesKit

/// The one piece of the app that cannot live in RacesKit: `Security.framework`
/// does not exist on Linux, and the Linux CI job is what keeps the kit honest.
/// `CredentialsStoring` is declared there; this implements it here.
///
/// `nonisolated` because this target defaults to MainActor isolation. A
/// MainActor-isolated class cannot satisfy `CredentialsStoring`'s nonisolated
/// requirements, and the kit reads credentials while building requests off the
/// main actor.
nonisolated final class KeychainCredentialsStore: CredentialsStoring {

    /// Every item is a generic password under this service, one account per slot.
    static let defaultService = "uk.co.suskins.Races.providers"

    private let service: String
    private let keychain: any KeychainOperating

    init(
        service: String = KeychainCredentialsStore.defaultService,
        keychain: any KeychainOperating = SystemKeychain()
    ) {
        self.service = service
        self.keychain = keychain
    }

    // MARK: - CredentialsStoring

    func read(_ slot: CredentialSlot) throws -> String? {
        var query = baseQuery(for: slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, item) = keychain.copyMatching(query)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.unexpectedItemFormat
            }
            // A value written by an older build could be anything; treat
            // undecodable bytes as absent rather than failing every read.
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    func write(_ value: String?, to slot: CredentialSlot) throws {
        guard let value, !value.isEmpty else {
            try delete(slot)
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(for: slot)

        // Update first: SecItemAdd on an existing account returns
        // errSecDuplicateItem, and "already there" is the common case — the user
        // correcting a typo, not creating something new.
        let updateStatus = keychain.update(query, [kSecValueData as String: data])
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            // Not `WhenUnlocked`: reconciliation runs from a background refresh
            // that can fire while the phone is locked, and it needs the
            // credentials to fetch results. `ThisDeviceOnly` keeps them out of
            // an iCloud or unencrypted backup.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            let addStatus = keychain.add(attributes)
            guard addStatus == errSecSuccess else {
                throw KeychainError.status(addStatus)
            }
        default:
            throw KeychainError.status(updateStatus)
        }
    }

    func removeAll() throws {
        for slot in CredentialSlot.allCases {
            try delete(slot)
        }
    }

    // MARK: - Helpers

    private func delete(_ slot: CredentialSlot) throws {
        let status = keychain.delete(baseQuery(for: slot))
        // Deleting something absent is the desired end state, not a failure.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private func baseQuery(for slot: CredentialSlot) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
        ]
    }
}

// MARK: - Errors

enum KeychainError: Error, Equatable {
    case status(OSStatus)
    case unexpectedItemFormat

    /// Worth spelling out: `-34018` is what a Keychain call returns when the
    /// process has no keychain-access entitlement, which is what happens in a
    /// test bundle built with `CODE_SIGNING_ALLOWED=NO`. It means the build is
    /// unsigned, not that the credentials are wrong.
    var isMissingEntitlement: Bool {
        self == .status(errSecMissingEntitlement)
    }
}

// MARK: - The seam

/// The four `SecItem*` calls, behind a protocol.
///
/// Not ceremony: the real Keychain is unreachable from a unit test bundle built
/// without signing, so testing this class against `SecItem*` directly would mean
/// a test that only runs on a signed device. The query-construction and
/// status-mapping logic is the part that actually breaks, and this seam lets CI
/// cover it.
protocol KeychainOperating: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychain: KeychainOperating {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
