import SwiftUI
import RacesKit

@main
struct RacesApp: App {
    /// The one place the Keychain is constructed. Everything downstream takes
    /// `any CredentialsStoring`, so views and view models can be driven by a
    /// fake without a signed container.
    private let credentials: any CredentialsStoring = KeychainCredentialsStore()

    var body: some Scene {
        WindowGroup {
            RootView(credentials: credentials)
        }
    }
}
