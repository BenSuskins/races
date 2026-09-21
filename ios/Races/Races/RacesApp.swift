import SwiftUI
import RacesKit

@main
struct RacesApp: App {

    @State private var environment: AppEnvironment

    init() {
        // The one place the Keychain is constructed. Everything downstream takes
        // `any CredentialsStoring`, so views and view models can be driven by a
        // fake without a signed container.
        let environment = AppEnvironment(credentials: KeychainCredentialsStore())
        _environment = State(initialValue: environment)

        // Must happen before launch finishes, which is why it is here and not in
        // a `.task`. Registering an identifier missing from
        // `BGTaskSchedulerPermittedIdentifiers` traps, so Info.plist and
        // `BackgroundRefresh.taskIdentifier` have to agree.
        BackgroundRefresh.register(environment: environment)
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
    }
}
