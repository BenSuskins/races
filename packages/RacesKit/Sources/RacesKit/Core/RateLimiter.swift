import Foundation

/// Paces outgoing requests so we stay inside a provider's published rate limit.
///
/// The Racing API's free tier allows **1 request per second**; Betfair is more
/// generous but weight-limited. Each provider client owns its own limiter, since
/// the limits are per-provider and unrelated.
///
/// Callers `await acquire()` immediately before sending. A slot is *reserved*
/// before the caller suspends, so concurrent callers are served in arrival order
/// and never collapse onto the same instant — actor re-entrancy during the sleep
/// is therefore harmless.
///
/// Uses `ContinuousClock` rather than `Date` so a wall-clock adjustment (NTP, the
/// user changing the time, a daylight-saving shift) can't cause a stampede or a
/// very long stall.
public actor RateLimiter {
    private let minimumInterval: Duration
    private let clock = ContinuousClock()
    private var nextAvailable: ContinuousClock.Instant?

    /// - Parameter requestsPerSecond: The provider's published limit. Pass a value
    ///   at or below it. Zero or negative disables pacing entirely.
    public init(requestsPerSecond: Double) {
        self.minimumInterval = requestsPerSecond > 0
            ? .seconds(1.0 / requestsPerSecond)
            : .zero
    }

    /// Reserve the next slot, suspending until it arrives.
    public func acquire() async throws {
        guard minimumInterval > .zero else { return }

        let now = clock.now
        let scheduled = max(now, nextAvailable ?? now)
        nextAvailable = scheduled.advanced(by: minimumInterval)

        if scheduled > now {
            try await Task.sleep(until: scheduled, clock: clock)
        }
    }

    /// Push every queued slot back, after the provider told us we were going too
    /// fast. Without this a 429 only delays the one request that was refused,
    /// and the requests already queued behind it march straight into another.
    public func penalise(by seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let floor = clock.now.advanced(by: .seconds(seconds))
        nextAvailable = max(nextAvailable ?? floor, floor)
    }

    /// Forget any reserved slots. Used by tests, and after a long period of
    /// inactivity where pacing against stale reservations would be pointless.
    public func reset() {
        nextAvailable = nil
    }
}
