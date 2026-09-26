import Foundation
import RacesKit

/// Settings: where the server is and its token.
///
/// The Racing API and Betfair credentials are no longer entered here. They
/// live in Ansible Vault on the homelab and only the server uses them; the
/// phone holds a token that lets it read.
@Observable
@MainActor
final class SettingsViewModel {

    nonisolated enum TestResult: Equatable {
        case untested
        case testing
        case succeeded(ServerStatus)
        case failed(APIError)
    }

    var serverURL = ""
    var token = ""

    private(set) var testResult: TestResult = .untested
    private(set) var saveError: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        loadExistingAddress()
    }

    var isConfigured: Bool { environment.configuration != nil }
    var isTesting: Bool { testResult == .testing }
    var credentialsFailure: APIError? { environment.credentialsFailure }
    var hasAnyStoredCredential: Bool { environment.hasAnyStoredCredential }
    var defaultServerURL: String { ServerConfiguration.defaultBaseURL.absoluteString }

    private func loadExistingAddress() {
        serverURL = (try? environment.read(.serverURL)) ?? ""
    }

    /// A new token, or an address change on a server already configured.
    var canSave: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConfigured
    }

    func save() {
        saveError = nil
        testResult = .untested
        let address = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try environment.write(address.isEmpty ? nil : address, to: .serverURL)
            if !newToken.isEmpty {
                try environment.write(newToken, to: .serverToken)
            }
            token = ""
        } catch {
            saveError = "Couldn't save to the Keychain."
            return
        }
        // The provider credentials this phone used to hold are the server's
        // job now. Clearing them is housekeeping, so a failure is not reported.
        for slot in CredentialSlot.legacyProviderSlots {
            try? environment.write(nil, to: slot)
        }
    }

    func clear() {
        saveError = nil
        testResult = .untested
        do {
            try environment.removeAllCredentials()
            serverURL = ""
            token = ""
        } catch {
            saveError = "Couldn't clear the Keychain."
        }
    }

    /// `GET /v1/status`: whether the server answers, and how its providers are.
    func test() async {
        guard let server = environment.server else {
            testResult = .failed(environment.unavailabilityReason ?? .notConfigured(provider: "The Races server"))
            return
        }
        testResult = .testing
        do {
            testResult = .succeeded(try await server.status())
        } catch {
            testResult = .failed(.from(error))
        }
    }

}
