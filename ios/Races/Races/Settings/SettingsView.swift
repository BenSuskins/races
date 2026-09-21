import SwiftUI
import RacesKit

/// Credentials, tier status, and the disclaimer.
struct SettingsView: View {
    @State private var model: SettingsViewModel

    init(environment: AppEnvironment) {
        _model = State(initialValue: SettingsViewModel(environment: environment))
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
                    Text("Market prices and starting prices arrive with Betfair support, which isn't built yet. Until then tips will run on the racecard alone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Clear credentials", role: .destructive) { model.clear() }
                        .disabled(!model.isConfigured)
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
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
