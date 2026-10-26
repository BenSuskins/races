import SwiftUI
import RacesKit

/// Renders a `ViewState<T>` so every screen treats async content identically:
/// a spinner while loading, `ErrorStateView` on failure, the caller's content
/// once loaded.
///
/// Ported from Family Hub's `StateContentView`, with one change that matters:
/// `ErrorStateView` distinguishes a genuine failure from an expected limitation,
/// because on the free tier the second is routine and must not look like a fault.
struct StateContentView<T, Content: View>: View {
    let state: ViewState<T>
    let retry: () async -> Void
    @ViewBuilder let content: (T) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
        case .failed(let error):
            ErrorStateView(error: error, retry: retry)
        case .loaded(let value):
            content(value)
        }
    }
}
