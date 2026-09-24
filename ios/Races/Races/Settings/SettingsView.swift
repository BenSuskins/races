import SwiftUI
import RacesKit

/// Where the server is, its token, and the one-off history upload.
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

                if model.hasHistoryToUpload {
                    Section {
                        Button {
                            Task { await model.uploadHistory() }
                        } label: {
                            if model.isUploading {
                                HStack { ProgressView(); Text("Uploading…") }
                            } else {
                                Text(model.historyUploadedAt == nil ? "Upload history" : "Upload history again")
                            }
                        }
                        .disabled(!model.isConfigured || model.isUploading)

                        UploadRow(result: model.uploadResult)
                    } header: {
                        Text("History from before the server")
                    } footer: {
                        if let uploadedAt = model.historyUploadedAt {
                            Text("Uploaded \(uploadedAt.formatted(date: .abbreviated, time: .shortened)). Sending it again is safe — the server keeps what it already has.")
                        } else {
                            Text("The tips, results archive and training data this phone collected on its own. Free results are today-only, so this is the only copy — send it once so the record and the model can use it.")
                        }
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

private struct UploadRow: View {
    let result: SettingsViewModel.UploadResult

    var body: some View {
        switch result {
        case .idle, .uploading:
            EmptyView()

        case .succeeded(let summary):
            VStack(alignment: .leading, spacing: 4) {
                Label("Uploaded — \(summary.tipsAdded + summary.tipsReplaced) new tips", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.green)
                Text(detail(summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)

        case .failed(let error):
            Label(error.errorDescription ?? "Couldn't upload", systemImage: "xmark.circle")
                .foregroundStyle(Color.red)
                .textSelection(.enabled)
        }
    }

    private func detail(_ s: ServerImportSummary) -> String {
        var parts = ["\(s.tipsKept) already on the server", "\(s.samplesAdded + s.pendingAdded) training races"]
        if s.archiveRacesAdded > 0 { parts.append("\(s.archiveRacesAdded) archived results") }
        if s.archiveSkipped { parts.append("results archive overlapped the server's and was not merged") }
        if !s.unreadableDocuments.isEmpty { parts.append("unreadable: \(s.unreadableDocuments.joined(separator: "; "))") }
        return parts.joined(separator: " · ") + "."
    }
}
