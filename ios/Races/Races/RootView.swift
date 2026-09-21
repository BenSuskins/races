import SwiftUI
import RacesKit

/// The app's tabs.
///
/// Three for now. Tips and Record are deliberately absent rather than present and
/// empty: a tab that leads nowhere is a promise the app hasn't kept, and each one
/// arrives with the milestone that fills it — Tips with the rating UI, Record once
/// the ledger has settled tips to report on.
struct RootView: View {
    @State private var environment: AppEnvironment

    init(credentials: any CredentialsStoring) {
        _environment = State(initialValue: AppEnvironment(credentials: credentials))
    }

    /// For previews and tests, which supply their own provider.
    init(environment: AppEnvironment) {
        _environment = State(initialValue: environment)
    }

    var body: some View {
        TabView {
            Tab("Today", systemImage: "calendar") {
                TodayView(environment: environment)
            }

            Tab("Courses", systemImage: "map") {
                CoursesView(environment: environment)
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
        case .racingAPIUsername: return "preview"
        case .racingAPIPassword: return "preview"
        default: return nil
        }
    }

    func write(_ value: String?, to slot: CredentialSlot) throws {}
    func removeAll() throws {}
}
