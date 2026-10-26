import SwiftUI
import RacesKit

/// The app's tabs.
struct RootView: View {
    @State private var environment: AppEnvironment

    init(credentials: any CredentialsStoring) {
        _environment = State(initialValue: AppEnvironment(credentials: credentials))
    }

    /// For previews and tests, which supply their own store and server.
    init(environment: AppEnvironment) {
        _environment = State(initialValue: environment)
    }

    var body: some View {
        TabView {
            Tab("Racing", systemImage: "calendar") {
                TodayView(environment: environment)
            }

            Tab("Tips", systemImage: "sparkles") {
                TipsView(environment: environment)
            }

            Tab("Model", systemImage: "slider.horizontal.3") {
                AlgorithmView(environment: environment)
            }

            Tab("Record", systemImage: "chart.line.uptrend.xyaxis") {
                RecordView(environment: environment)
            }

            Tab("Settings", systemImage: "gear") {
                SettingsView(environment: environment)
            }
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
        case .serverToken: return "preview"
        default: return nil
        }
    }

    func write(_ value: String?, to slot: CredentialSlot) throws {}
    func removeAll() throws {}
}
