import SwiftUI
import RacesKit

/// Credentials, tier status, and the disclaimer.
struct SettingsView: View {
    @State private var model: SettingsViewModel
    @State private var betfair: BetfairSettingsViewModel
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: SettingsViewModel(environment: environment))
        _betfair = State(initialValue: BetfairSettingsViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let credentialsFailure = model.credentialsFailure {
                    Section {
                        Label(
                            credentialsFailure.errorDescription ?? "Couldn't read the Keychain.",
                            systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField(
                        model.isConfigured ? "Password (saved)" : "Password",
                        text: $model.password)
                        .textContentType(.password)

                    Button("Save") { model.save() }
                        .disabled(!model.canSave)
                } header: {
                    Text("The Racing API")
                } footer: {
                    Text("Stored in the device Keychain. Nothing is sent anywhere but The Racing API.")
                }

                Section {
                    Button {
                        Task { await model.test() }
                    } label: {
                        if model.isTesting {
                            HStack { ProgressView(); Text("Testing…") }
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(!model.isConfigured || model.isTesting)

                    TestResultRow(result: model.testResult)
                }

                if let saveError = model.saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red)
                    }
                }

                Section {
                    TextField("Application key", text: $betfair.appKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Username", text: $betfair.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField(
                        betfair.isConfigured ? "Password (saved)" : "Password",
                        text: $betfair.password)
                        .textContentType(.password)

                    Button("Save") { betfair.save() }
                        .disabled(!betfair.canSave)
                } header: {
                    Text("Betfair")
                } footer: {
                    Text("Optional. Without it, tips are read off the racecard alone — the app works, but the model has no market to anchor to. The free delayed application key is enough.")
                }

                Section {
                    Button {
                        Task { await betfair.test() }
                    } label: {
                        if betfair.isTesting {
                            HStack { ProgressView(); Text("Testing…") }
                        } else {
                            Text("Test Betfair")
                        }
                    }
                    .disabled(!betfair.isConfigured || betfair.isTesting)

                    BetfairTestResultRow(result: betfair.testResult)

                    Button("Remove Betfair", role: .destructive) { betfair.clear() }
                        .disabled(!betfair.isConfigured)
                }

                if let saveError = betfair.saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Clear all credentials", role: .destructive) { model.clear() }
                        .disabled(!environment.hasAnyStoredCredential)
                }

                Section {
                    Text("For information only. Not betting advice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Betfair's three refusals, each with the instruction that actually applies.
///
/// Being told to check a password that is correct is worse than being told
/// nothing, so a 2FA challenge and a certificate requirement say what they are
/// and carry Betfair's own code for anyone who needs to look it up.
private struct BetfairTestResultRow: View {
    let result: BetfairSettingsViewModel.TestResult

    var body: some View {
        switch result {
        case .untested, .testing:
            EmptyView()
        case .succeeded(let marketCount):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connected — \(marketCount) win markets today", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.green)
                if marketCount == 0 {
                    Text("The login worked; there is just no GB or Irish racing listed right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .refused(let failure):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    failure.message,
                    systemImage: failure.isInformational ? "info.circle" : "xmark.circle")
                    // Explicit, because a `Label` in this section otherwise
                    // inherits the section's tint and renders a failure in the
                    // same green as a success.
                    .foregroundStyle(failure.isInformational ? Color.primary : Color.red)
                if failure.requiresCertificateLogin {
                    Text("Nothing you can change here will fix this. Certificate login isn't supported yet — tips will stay form-only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if failure.requiresUserAction {
                    Text("Sign in at betfair.com, clear whatever it asks for, then test again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if failure.isUnreadableResponse {
                    Text("Your credentials were never sent for checking, so there is nothing to re-type. If you are abroad or on a VPN, try again from a UK connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    error.errorDescription ?? "Couldn't connect",
                    systemImage: error.isExpectedLimitation ? "info.circle" : "xmark.circle")
                    .foregroundStyle(error.isExpectedLimitation ? Color.primary : Color.red)
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TestResultRow: View {
    let result: SettingsViewModel.TestResult

    var body: some View {
        switch result {
        case .untested, .testing:
            EmptyView()
        case .succeeded(let courseCount, let capability):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connected — \(courseCount) courses", systemImage: "checkmark.circle")
                Text(capability.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    error.errorDescription ?? "Couldn't connect",
                    systemImage: error.isExpectedLimitation ? "info.circle" : "xmark.circle")
                    .foregroundStyle(error.isExpectedLimitation ? Color.primary : Color.red)
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
