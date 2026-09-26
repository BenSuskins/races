import SwiftUI
import RacesKit

/// Where the server is and its token.
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
                    TextField(model.defaultServerURL, text: $model.serverURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(
                        model.isConfigured ? "API token (saved)" : "API token",
                        text: $model.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") { model.save() }
                        .disabled(!model.canSave)
                } header: {
                    Text("Races server")
                } footer: {
                    Text("Leave the address blank for the homelab default. The server holds the Racing API and Betfair credentials and does all the collecting; this phone keeps only its token, in the Keychain. Reachable at home or over Tailscale.")
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

                    StatusRow(result: model.testResult)
                }

                if let saveError = model.saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Clear saved server details", role: .destructive) { model.clear() }
                        .disabled(!model.hasAnyStoredCredential)
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

/// What `GET /v1/status` said. Selectable, because a diagnostic nobody can
/// copy is a diagnostic nobody can report.
private struct StatusRow: View {
    let result: SettingsViewModel.TestResult

    var body: some View {
        switch result {
        case .untested, .testing:
            EmptyView()

        case .succeeded(let status):
            VStack(alignment: .leading, spacing: 6) {
                Label("Connected — server \(status.version), weights \(status.activeWeightsID)", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.green)
                ProviderLine(name: "The Racing API", status: status.racingAPI)
                ProviderLine(name: "Betfair", status: status.betfair)
                if let tips = status.counts["tips"], let results = status.counts["results"] {
                    Text("\(tips) tips, \(results) results stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)

        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    error.errorDescription ?? "Couldn't connect",
                    systemImage: error.isExpectedLimitation ? "info.circle" : "xmark.circle")
                    .foregroundStyle(error.isExpectedLimitation ? Color.primary : Color.red)
                if error == .unauthorized {
                    Text("The server refused the token. Check it matches RACES_API_TOKEN in the vault.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("At home, check the server is running. Away, check Tailscale is connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
        }
    }
}

private struct ProviderLine: View {
    let name: String
    let status: ServerProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(line, systemImage: icon)
                .font(.caption)
                .foregroundStyle(status.healthy ? Color.secondary : Color.orange)
            if let failure = status.loginFailure {
                Text(failure.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        if !status.configured { return "minus.circle" }
        return status.healthy ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var line: String {
        if !status.configured { return "\(name): not configured on the server" }
        if status.healthy { return "\(name): working" }
        return "\(name): \(status.detail ?? "failing")"
    }
}
