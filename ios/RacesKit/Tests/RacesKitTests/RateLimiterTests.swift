import XCTest
@testable import RacesKit

final class RateLimiterTests: XCTestCase {

    func test_firstAcquire_isImmediate() async throws {
        let limiter = RateLimiter(requestsPerSecond: 1)
        let clock = ContinuousClock()

        let elapsed = try await clock.measure {
            try await limiter.acquire()
        }

        XCTAssertLessThan(elapsed, .milliseconds(100), "the first request should not be delayed")
    }

    func test_sequentialAcquires_arePacedByTheInterval() async throws {
        // 20/sec → a 50ms interval. Three acquires cost 0 + 50 + 50 = ~100ms.
        let limiter = RateLimiter(requestsPerSecond: 20)
        let clock = ContinuousClock()

        let elapsed = try await clock.measure {
            try await limiter.acquire()
            try await limiter.acquire()
            try await limiter.acquire()
        }

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(80), "pacing was not applied")
        XCTAssertLessThan(elapsed, .seconds(2), "pacing overshot badly")
    }

    /// Concurrent callers must each get their own slot rather than all waking at
    /// once — otherwise a burst of parallel requests would blow the provider's
    /// limit despite the limiter being present.
    func test_concurrentAcquires_eachReserveASeparateSlot() async throws {
        let limiter = RateLimiter(requestsPerSecond: 20) // 50ms apart
        let clock = ContinuousClock()

        let elapsed = try await clock.measure {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask { try await limiter.acquire() }
                }
                try await group.waitForAll()
            }
        }

        // Four slots at 50ms → the last one lands at ~150ms.
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(120), "concurrent callers collapsed onto one slot")
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    func test_zeroRate_disablesPacing() async throws {
        let limiter = RateLimiter(requestsPerSecond: 0)
        let clock = ContinuousClock()

        let elapsed = try await clock.measure {
            for _ in 0..<50 { try await limiter.acquire() }
        }

        XCTAssertLessThan(elapsed, .milliseconds(200), "pacing should be disabled entirely")
    }

    /// A 429 must delay everything already queued, not just the request that was
    /// refused — otherwise the queue marches straight into another refusal.
    func test_penalise_pushesTheQueueBack() async throws {
        let limiter = RateLimiter(requestsPerSecond: 1000) // effectively unpaced
        await limiter.penalise(by: 0.3)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await limiter.acquire()
        }

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(250))
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func test_penalise_ignoresNonPositiveDelays() async throws {
        let limiter = RateLimiter(requestsPerSecond: 1000)
        await limiter.penalise(by: 0)
        await limiter.penalise(by: -5)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await limiter.acquire()
        }

        XCTAssertLessThan(elapsed, .milliseconds(200))
    }

    func test_reset_clearsReservedSlots() async throws {
        let limiter = RateLimiter(requestsPerSecond: 2) // 500ms apart
        try await limiter.acquire()
        await limiter.reset()

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await limiter.acquire()
        }

        XCTAssertLessThan(elapsed, .milliseconds(200), "reset should drop the reservation")
    }
}
