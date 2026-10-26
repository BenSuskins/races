import XCTest
@testable import RacesKit

final class RetryPolicyTests: XCTestCase {

    // MARK: - Delay calculation

    func test_delay_growsExponentially() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 100, jitter: 0)

        XCTAssertEqual(policy.delay(forAttempt: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 4), 8, accuracy: 0.0001)
    }

    func test_delay_isCappedAtMaxDelay() {
        let policy = RetryPolicy(maxAttempts: 20, baseDelay: 1, maxDelay: 5, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 10), 5, accuracy: 0.0001)
    }

    func test_delay_staysWithinJitterBand() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 100, jitter: 0.2)
        for _ in 0..<200 {
            let delay = policy.delay(forAttempt: 1)
            XCTAssertGreaterThanOrEqual(delay, 0.8)
            XCTAssertLessThanOrEqual(delay, 1.2)
        }
    }

    func test_retryAfter_takesPrecedenceOverBackoff() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 100, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 5, retryAfter: 2), 2, accuracy: 0.0001)
    }

    /// A provider could send an absurd `Retry-After`; the cap stops it hanging the app.
    func test_retryAfter_isStillCapped() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 5, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: 3600), 5, accuracy: 0.0001)
    }

    func test_presets() {
        XCTAssertEqual(RetryPolicy.default.maxAttempts, 3)
        XCTAssertEqual(RetryPolicy.none.maxAttempts, 1)
    }

    // MARK: - withRetry

    func test_withRetry_returnsFirstSuccessWithoutRetrying() async throws {
        var attempts = 0
        let result = try await withRetry(policy: .default, shouldRetry: { _ in true }) {
            attempts += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 1)
    }

    func test_withRetry_retriesUntilSuccess() async throws {
        var attempts = 0
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 0.001, maxDelay: 0.01, jitter: 0)

        let result = try await withRetry(policy: policy, shouldRetry: { $0.isRetryable }) {
            attempts += 1
            if attempts < 3 { throw APIError.timedOut }
            return attempts
        }

        XCTAssertEqual(result, 3)
        XCTAssertEqual(attempts, 3)
    }

    func test_withRetry_stopsAtMaxAttempts() async {
        var attempts = 0
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.001, maxDelay: 0.01, jitter: 0)

        do {
            _ = try await withRetry(policy: policy, shouldRetry: { $0.isRetryable }) {
                attempts += 1
                throw APIError.timedOut
            }
            XCTFail("Expected to throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertEqual(attempts, 3)
    }

    func test_withRetry_honoursShouldRetryPredicate() async {
        var attempts = 0
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.001, maxDelay: 0.01, jitter: 0)

        do {
            _ = try await withRetry(policy: policy, shouldRetry: { _ in false }) {
                attempts += 1
                throw APIError.timedOut
            }
            XCTFail("Expected to throw")
        } catch {
            // expected
        }

        XCTAssertEqual(attempts, 1, "shouldRetry returning false must stop immediately")
    }

    func test_withRetry_normalisesThrownErrorsToAPIError() async {
        struct Mystery: Error {}
        do {
            _ = try await withRetry(policy: .none, shouldRetry: { _ in false }) {
                throw Mystery()
            }
            XCTFail("Expected to throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .network(URLError(.unknown)))
        } catch {
            XCTFail("Expected an APIError, got \(error)")
        }
    }
}
