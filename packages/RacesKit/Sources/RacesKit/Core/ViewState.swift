import Foundation

/// The lifecycle of a piece of async content, so every screen treats loading,
/// failure and success identically. Paired with `StateContentView` in the app
/// target, which switches on it once so no individual view has to.
public enum ViewState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(APIError)

    /// The value if loaded, otherwise nil. Useful for "keep showing the old
    /// content while refreshing" behaviour.
    public var value: T? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
