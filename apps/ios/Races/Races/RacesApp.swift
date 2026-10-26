import SwiftUI
import RacesKit

@main
struct RacesApp: App {

    @State private var environment: AppEnvironment

    init() {
        // The one place the Keychain is constructed. Everything downstream takes
        // `any CredentialsStoring`, so views and view models can be driven by a
        // fake without a signed container.
        //
        // There is no background task any more: the server collects results
        // all evening whether or not a phone is awake.
        _environment = State(initialValue: AppEnvironment(credentials: KeychainCredentialsStore()))
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
    }
}
