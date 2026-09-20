import XCTest
@testable import RacesKit

final class ResultReconcilerTests: XCTestCase {

    private let off = Date(timeIntervalSince1970: 1_800_000_000)
    private var evening: Date { off.addingTimeInterval(4 * 3600) }

    // MARK: - Settled outcomes

    func test_aWinningTipIsSettledAsWon() {
        let tip = TipRecord.make(selection: "hrs_1", offAt: off)
        let result = TestResult.result(
            finishing: [("hrs_1", "1"), ("hrs_2", "2"), ("hrs_3", "3")],
            startingPrices: ["hrs_1": 4.2]
        )

        let settled = ResultReconciler.settle(tip: tip, result: result, now: evening)

        XCTAssertEqual(settled.outcome, .won(betfairSP: 4.2))
        XCTAssertEqual(settled.outcome?.isSettled, true)
    }

    func test_aBeatenTipIsSettledAsLostWithItsPosition() {
        let tip = TipRecord.make(selection: "hrs_2", offAt: off)
        let result = TestResult.result(
            finishing: [("hrs_1", "1"), ("hrs_2", "4"), ("hrs_3", "3")],
            startingPrices: ["hrs_2": 6.0]
        )

        let settled = ResultReconciler.settle(tip: tip, result: result, now: evening)

        XCTAssertEqual(settled.outcome, .lost(position: 4, betfairSP: 6.0))
    }

    /// A non-completion is a loss, but with no finishing position to report.
    func test_aPulledUpTipIsLostWithNoPosition() {
        let tip = TipRecord.make(selection: "hrs_2", offAt: off)
        let result = TestResult.result(finishing: [("hrs_1", "1"), ("hrs_2", "PU"), ("hrs_3", "2")])

        let settled = ResultReconciler.settle(tip: tip, result: result, now: evening)

        XCTAssertEqual(settled.outcome, .lost(position: nil, betfairSP: nil))
    }

    /// Betfair SP takes precedence: the free results endpoint carries no price
    /// at all, and where a paid tier does supply one, BSP is the better basis.
    func test_betfairStartingPriceOverridesTheProviders() {
        let tip = TipRecord.make(selection: "hrs_1", offAt: off)
        let result = TestResult.result(
            finishing: [("hrs_1", "1"), ("hrs_2", "2"), ("hrs_3", "3")],
            startingPrices: ["hrs_1": 4.0]
        )

        let settled = ResultReconciler.settle(
            tip: tip, result: result,
            betfairStartingPrices: ["hrs_1": 4.6], now: evening
        )

        XCTAssertEqual(settled.outcome, .won(betfairSP: 4.6))
    }

    // MARK: - Void

    /// The distinction the whole tracker depends on: a withdrawn horse is a void
    /// bet, not a losing one.
    func test_aWithdrawnSelectionIsVoidNotBeaten() {
        let tip = TipRecord.make(selection: "hrs_9", offAt: off)
        let result = TestResult.result(finishing: [("hrs_1", "1"), ("hrs_2", "2"), ("hrs_3", "3")])

        let settled = ResultReconciler.settle(tip: tip, result: result, now: evening)

        XCTAssertEqual(settled.outcome, .nonRunner)
        XCTAssertEqual(settled.outcome?.isVoid, true)
        XCTAssertEqual(settled.outcome?.isSettled, false)
    }

    func test_anAbandonedMeetingIsVoid() {
        let tip = TipRecord.make(offAt: off)

        let settled = ResultReconciler.settle(
            tip: tip, result: nil, meetingAbandoned: true, now: evening
        )

        XCTAssertEqual(settled.outcome, .abandoned)
    }

    /// A truncated payload must not settle everyone as a non-runner and wipe a
    /// day of tips in one pass, so a suspiciously small field is treated as
    /// "still looking" rather than as evidence.
    func test_aTruncatedResultDoesNotSettleAnything() {
        let tip = TipRecord.make(selection: "hrs_9", offAt: off)
        let sparse = TestResult.result(finishing: [("hrs_1", "1")])

        let settled = ResultReconciler.settle(tip: tip, result: sparse, now: evening)

        guard case .unresolved = settled.outcome else {
            return XCTFail("Expected to keep looking, got \(String(describing: settled.outcome))")
        }
    }

    // MARK: - Missing results

    func test_aMissingResultKeepsTryingAndCountsAttempts() {
        var tip = TipRecord.make(offAt: off)

        tip = ResultReconciler.settle(tip: tip, result: nil, now: evening)
        guard case .unresolved(_, let first) = tip.outcome else {
            return XCTFail("expected unresolved")
        }
        XCTAssertEqual(first, 1)

        tip = ResultReconciler.settle(tip: tip, result: nil, now: evening)
        guard case .unresolved(_, let second) = tip.outcome else {
            return XCTFail("expected unresolved")
        }
        XCTAssertEqual(second, 2)
    }

    /// The free results endpoint covers today only. Miss an evening and those
    /// results are gone, so the tip expires rather than pending forever — and is
    /// counted, so the coverage figure stays honest.
    func test_aTipGivesUpOnceItIsTooOld() {
        let tip = TipRecord.make(offAt: off)
        let muchLater = off.addingTimeInterval(Double(ResultReconciler.expiryDays + 1) * 24 * 3600)

        let settled = ResultReconciler.settle(tip: tip, result: nil, now: muchLater)

        guard case .expired = settled.outcome else {
            return XCTFail("Expected expiry, got \(String(describing: settled.outcome))")
        }
    }

    func test_aTipGivesUpAfterTooManyAttempts() {
        let tip = TipRecord.make(
            offAt: off,
            outcome: .unresolved(lastCheckedAt: off, attempts: ResultReconciler.maximumAttempts - 1)
        )

        let settled = ResultReconciler.settle(tip: tip, result: nil, now: evening)

        guard case .expired = settled.outcome else {
            return XCTFail("Expected expiry, got \(String(describing: settled.outcome))")
        }
    }

    // MARK: - The favourite baseline

    /// Captured now because the free results endpoint will not have this race
    /// tomorrow, and the baseline is the only honest answer to "is this any good?"
    func test_theFavouritesOutcomeIsCapturedAtSettlement() throws {
        let tip = TipRecord.make(selection: "hrs_2", marketFavouriteHorseID: "hrs_1",
                                 agreedWithFavourite: false, offAt: off)
        let result = TestResult.result(
            finishing: [("hrs_1", "1"), ("hrs_2", "2"), ("hrs_3", "3")],
            startingPrices: ["hrs_1": 2.5]
        )

        let settled = ResultReconciler.settle(tip: tip, result: result, now: evening)
        let favourite = try XCTUnwrap(settled.favouriteOutcome)

        XCTAssertEqual(favourite.horseID, "hrs_1")
        XCTAssertTrue(favourite.won)
        XCTAssertEqual(favourite.betfairSP, 2.5)
    }

    func test_aWithdrawnFavouriteIsNotRecordedAsBeaten() {
        let tip = TipRecord.make(selection: "hrs_2", marketFavouriteHorseID: "hrs_9",
                                 agreedWithFavourite: false, offAt: off)
        let result = TestResult.result(finishing: [("hrs_1", "1"), ("hrs_2", "2"), ("hrs_3", "3")])

        let settled = ResultReconciler.settle(tip: tip, result: result, now: evening)

        XCTAssertNil(settled.favouriteOutcome, "a non-running favourite is not a losing favourite")
    }
}
