import SwiftUI
import RacesKit

/// Placeholder root.
///
/// The real navigation — Today, Courses, Tips, Record, Settings — arrives with
/// the browse milestone. This exists so the project has a buildable app target
/// that genuinely links RacesKit, and so the disclaimer is present from the
/// first build rather than remembered later.
struct RootView: View {
    private let credentials: any CredentialsStoring

    @State private var configuration: ProviderConfiguration?
    @State private var configurationError: String?

    init(credentials: any CredentialsStoring) {
        self.credentials = credentials
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Providers") {
                    if let configurationError {
                        Label(configurationError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else {
                        providerRow(
                            "The Racing API",
                            isConfigured: configuration?.racingAPI != nil)
                        providerRow(
                            "Betfair Exchange",
                            isConfigured: configuration?.betfair != nil)
                    }
                }

                Section {
                    Text("Racecards, ratings and tip tracking arrive in the next milestone.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("For information only. Not betting advice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Races")
        }
        .task {
            do {
                configuration = try ProviderConfiguration(reading: credentials)
            } catch {
                // A failing Keychain is worth saying out loud. Reading it as
                // "nothing configured" would invite the user to re-enter
                // credentials they have already given us.
                configurationError = "Couldn't read the Keychain."
            }
        }
    }

    private func providerRow(_ name: String, isConfigured: Bool) -> some View {
        LabeledContent(name) {
            Text(isConfigured ? "Configured" : "Not set up")
                .foregroundStyle(isConfigured ? .primary : .secondary)
        }
    }
}

#Preview {
    RootView(credentials: PreviewCredentialsStore())
}

/// Previews must not touch the Keychain — it is unavailable in the preview
/// container and would throw `errSecMissingEntitlement`.
///
/// `nonisolated` because this target defaults to MainActor isolation, and a
/// MainActor-isolated class cannot satisfy `CredentialsStoring`'s nonisolated
/// requirements — the kit reads credentials from off the main actor.
private nonisolated final class PreviewCredentialsStore: CredentialsStoring {
    func read(_ slot: CredentialSlot) throws -> String? {
        switch slot {
        case .racingAPIUsername: return "preview"
        case .racingAPIPassword: return "preview"
        default: return nil
        }
    }

    func write(_ value: String?, to slot: CredentialSlot) throws {}
    func removeAll() throws {}
}
