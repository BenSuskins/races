import Foundation

/// A single secret the user enters in Settings.
///
/// Flat slots rather than one blob: the Keychain stores generic-password items
/// keyed by account.
///
/// Only the two server slots are entered now. The provider slots are what the
/// app used before the server held the Racing API and Betfair credentials;
/// they stay in the enum so `removeAll()` still reaches any value a device
/// saved back then, and Settings clears them once the server is connected.
public enum CredentialSlot: String, CaseIterable, Sendable {
    case serverURL
    case serverToken
    case racingAPIUsername
    case racingAPIPassword
    case betfairAppKey
    case betfairUsername
    case betfairPassword

    /// The slots the app no longer asks for.
    public static let legacyProviderSlots: [CredentialSlot] = [
        .racingAPIUsername, .racingAPIPassword, .betfairAppKey, .betfairUsername, .betfairPassword,
    ]

    /// What Settings calls this field.
    public var label: String {
        switch self {
        case .serverURL: return "Server address"
        case .serverToken: return "API token"
        case .racingAPIUsername: return "Username"
        case .racingAPIPassword: return "Password"
        case .betfairAppKey: return "Application key"
        case .betfairUsername: return "Username"
        case .betfairPassword: return "Password"
        }
    }

    public var isSecret: Bool {
        switch self {
        case .serverToken, .racingAPIPassword, .betfairPassword: return true
        case .serverURL, .racingAPIUsername, .betfairAppKey, .betfairUsername: return false
        }
    }
}

/// Where secrets live. **Declared here, implemented in the app target.**
///
/// `Security.framework` does not exist on Linux, and this package is
/// Foundation-only so the Linux CI job can test it in seconds. So the Keychain
/// implementation lives in the app and everything in the kit talks to this.
public protocol CredentialsStoring: AnyObject, Sendable {
    func read(_ slot: CredentialSlot) throws -> String?
    func write(_ value: String?, to slot: CredentialSlot) throws
    func removeAll() throws
}

/// What the app can actually do with the secrets it has.
public struct ProviderConfiguration: Equatable, Sendable {
    public struct RacingAPI: Equatable, Sendable {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public struct Betfair: Equatable, Sendable {
        public let appKey: String
        public let username: String
        public let password: String

        public init(appKey: String, username: String, password: String) {
            self.appKey = appKey
            self.username = username
            self.password = password
        }
    }

    public let racingAPI: RacingAPI?
    public let betfair: Betfair?

    public init(racingAPI: RacingAPI?, betfair: Betfair?) {
        self.racingAPI = racingAPI
        self.betfair = betfair
    }

    /// Neither provider configured. A normal first-run state, not an error.
    public var isEmpty: Bool { racingAPI == nil && betfair == nil }

    /// Reads every slot and assembles whichever providers are **completely**
    /// configured.
    ///
    /// Half-configured is not configured. A username with no password would
    /// otherwise produce a request that 401s, and the user would be told their
    /// credentials are wrong rather than that one field is blank — the least
    /// helpful possible reading of the situation.
    public init(reading store: any CredentialsStoring) throws {
        func value(_ slot: CredentialSlot) throws -> String? {
            guard let raw = try store.read(slot) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let username = try value(.racingAPIUsername),
           let password = try value(.racingAPIPassword) {
            self.racingAPI = RacingAPI(username: username, password: password)
        } else {
            self.racingAPI = nil
        }

        if let appKey = try value(.betfairAppKey),
           let username = try value(.betfairUsername),
           let password = try value(.betfairPassword) {
            self.betfair = Betfair(appKey: appKey, username: username, password: password)
        } else {
            self.betfair = nil
        }
    }
}
