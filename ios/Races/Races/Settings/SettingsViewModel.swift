import Foundation
import RacesKit

/// Credential entry, and a connection test that reports the detected tier.
///
/// Drafts are held separately from the Keychain and written on an explicit save,
/// so a half-typed password is never stored — `ProviderConfiguration` treats a
/// username with no password as "not configured", and a partial write would make
/// the app claim to be set up when it would 401.
@Observable
@MainActor
final class SettingsViewModel {

    nonisolated enum TestResult: Equatable {
        case untested
        case testing
        case succeeded(courseCount: Int, capability: ProviderCapability)
        case failed(APIError)
    }

    var username = ""
    var password = ""

    private(set) var testResult: TestResult = .untested
    private(set) var saveError: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        loadExistingUsername()
    }

    var isConfigured: Bool { environment.configuration?.racingAPI != nil }
    var isTesting: Bool { testResult == .testing }
    var credentialsFailure: APIError? { environment.credentialsFailure }

    /// The username is not a secret, so showing it back confirms which account is
    /// in use. The password is never read back into the form — there is no way to
    /// display it that is more useful than blank, and a populated field would
    /// imply editing it in place is safe when submitting it unchanged is not.
    private func loadExistingUsername() {
        do {
            username = try environment.read(.racingAPIUsername) ?? ""
        } catch {
            username = ""
        }
    }

    var canSave: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    func save() {
        saveError = nil
        testResult = .untested
        do {
            try environment.write(username.trimmingCharacters(in: .whitespaces), to: .racingAPIUsername)
            try environment.write(password, to: .racingAPIPassword)
            password = ""
        } catch {
            saveError = "Couldn't save to the Keychain."
        }
    }

    func clear() {
        saveError = nil
        testResult = .untested
        do {
            try environment.removeAllCredentials()
            username = ""
            password = ""
        } catch {
            saveError = "Couldn't clear the Keychain."
        }
    }

    /// Ask for the course list — the cheapest authenticated call there is, and one
    /// every tier allows, so a failure here is about credentials and nothing else.
    func test() async {
        guard let provider = environment.racingProvider else {
            testResult = .failed(.notConfigured(provider: "The Racing API"))
            return
        }

        testResult = .testing
        do {
            let courses = try await provider.courses(regionCodes: BrowseRegions.codes)
            testResult = .succeeded(
                courseCount: courses.count,
                capability: await provider.capability)
        } catch {
            testResult = .failed(.from(error))
        }
    }
}
