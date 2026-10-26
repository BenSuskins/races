import SwiftUI
import RacesKit

/// What the user sees when a provider call doesn't produce content.
///
/// The split on `isExpectedLimitation` is the point of this view. An unconfigured
/// provider and a paid-tier endpoint are *normal states* of this app — the free
/// tier is the design centre, not a degraded mode — so they get an informational
/// presentation and no retry button, because retrying cannot help. Only real
/// failures get the warning treatment and a way to try again.
///
/// Getting this backwards would train the user to ignore a red banner that says
/// nothing is wrong, and then they'd ignore the one that means it.
struct ErrorStateView: View {
    let error: APIError
    let retry: () async -> Void

    private var isInformational: Bool { error.isExpectedLimitation }

    var body: some View {
        ContentUnavailableView {
            Label(
                error.errorDescription ?? "Something went wrong",
                systemImage: isInformational ? "info.circle" : "exclamationmark.triangle")
        } description: {
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
            }
        } actions: {
            if !isInformational {
                Button("Try Again") {
                    Task { await retry() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

#Preview("Real failure") {
    ErrorStateView(error: .offline, retry: {})
}

#Preview("Expected limitation") {
    ErrorStateView(error: .notConfigured(provider: "The Racing API"), retry: {})
}
