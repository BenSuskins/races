import Foundation
import RacesKit

/// Betfair credential entry, and a connection test that says which kind of
/// failure it was.
///
/// A separate view model from `SettingsViewModel` rather than three more fields
/// on it: the two providers are configured independently, and the failure modes
/// have nothing in common. The Racing API either accepts a key or does not,
/// while Betfair has three distinct refusals and only one of them is answered by
/// re-typing a password.
@Observable
@MainActor
final class BetfairSettingsViewModel {

    /// The outcome of a login attempt, classified the way the user needs it.
    ///
    /// `nonisolated` for the reason in CLAUDE.md: the app target infers isolated
    /// conformances, and a main-actor-isolated `Equatable` cannot satisfy
    /// `XCTAssertEqual`'s constraint from a nonisolated test method.
    nonisolated enum TestResult: Equatable {
        case untested
        case testing
        /// Logged in and the exchange answered. The count is how many GB and
        /// Irish win markets it offered for today — the useful number, because a
        /// successful login with no markets is a different situation from a
        /// working setup.
        case succeeded(marketCount: Int)
        /// Betfair refused the login, and said why.
        case refused(BetfairLoginFailure)
        /// Anything else — offline, a bad app key, a 500.
        case failed(APIError)
    }

    var appKey = ""
    var username = ""
    var password = ""

    private(set) var testResult: TestResult = .untested
    private(set) var saveError: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        loadExistingFields()
    }

    var isConfigured: Bool { environment.configuration?.betfair != nil }
    var isTesting: Bool { testResult == .testing }

    /// The app key and username are not secrets, so they are read back — a key
    /// with a typo in it is otherwise invisible. The password never is: there is
    /// no way to show it that beats blank, and a populated field would imply
    /// submitting it unchanged works when it does not.
    private func loadExistingFields() {
        do {
            appKey = try environment.read(.betfairAppKey) ?? ""
            username = try environment.read(.betfairUsername) ?? ""
        } catch {
            appKey = ""
            username = ""
        }
    }

    var canSave: Bool {
        !appKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    func save() {
        saveError = nil
        testResult = .untested
        do {
            try environment.write(appKey.trimmingCharacters(in: .whitespaces), to: .betfairAppKey)
            try environment.write(username.trimmingCharacters(in: .whitespaces), to: .betfairUsername)
            try environment.write(password, to: .betfairPassword)
            password = ""
        } catch {
            saveError = "Couldn't save to the Keychain."
        }
    }

    /// Clears only Betfair. Losing the Racing API key as well would leave the
    /// app with no card at all, which is not what "remove Betfair" means.
    func clear() {
        saveError = nil
        testResult = .untested
        do {
            try environment.write(nil, to: .betfairAppKey)
            try environment.write(nil, to: .betfairUsername)
            try environment.write(nil, to: .betfairPassword)
            appKey = ""
            username = ""
            password = ""
        } catch {
            saveError = "Couldn't clear the Keychain."
        }
    }

    /// Log in and ask for today's win markets.
    ///
    /// The catalogue call is the cheapest thing that proves the whole chain: it
    /// needs a session token, so a login failure surfaces here, and it needs the
    /// app key to be valid for the exchange rather than just well-formed.
    func test() async {
        guard let provider = environment.marketProvider else {
            testResult = .failed(.notConfigured(provider: "Betfair"))
            return
        }

        testResult = .testing
        do {
            let markets = try await provider.markets(day: .today)
            testResult = .succeeded(marketCount: markets.count)
        } catch let failure as BetfairLoginFailure {
            // Kept as itself rather than mapped to an `APIError`, because the
            // three classes need three different instructions and the raw code
            // is the one thing worth reporting verbatim.
            testResult = .refused(failure)
        } catch {
            testResult = .failed(.from(error))
        }
    }
}
