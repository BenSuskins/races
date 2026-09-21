import SwiftUI
import RacesKit

/// The app's tabs.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var environment: AppEnvironment

    init(credentials: any CredentialsStoring) {
        _environment = State(initialValue: AppEnvironment(credentials: credentials))
    }

    /// For previews and tests, which supply their own store and provider.
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

            Tab("Courses", systemImage: "map") {
                CoursesView(environment: environment)
            }

            Tab("Record", systemImage: "chart.line.uptrend.xyaxis") {
                RecordView(environment: environment)
            }

            Tab("Settings", systemImage: "gear") {
                SettingsView(environment: environment)
            }
        }
        .task {
            // Collect today's results on every launch. The free endpoint is
            // today-only, so a launch is an opportunity that does not come back.
            await environment.refreshResults()
        }
        .onChange(of: scenePhase) { _, phase in
            // Ask for the next background run on the way out, which is when the
            // system wants to hear it and when we know we are about to stop
            // collecting in the foreground.
            if phase == .background {
                BackgroundRefresh.schedule()
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
