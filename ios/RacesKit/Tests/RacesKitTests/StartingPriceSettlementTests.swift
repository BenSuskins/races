import XCTest
@testable import RacesKit

/// Settling a tip with a Betfair starting price, and the ROI that follows.
///
/// The free Racing API results endpoint carries **no** starting price, so
/// without this path the Record tab has a strike rate and no ROI for ever.
/// These tests are about the seam holding rather than the arithmetic, which
/// `AccuracyMetricsTests` already covers.
final class StartingPriceSettlementTests: XCTestCase {

    private static let off = Date(timeIntervalSince1970: 1_800_000_000)
    private static let afterwards = StartingPriceSettlementTests.off.addingTimeInterval(1_800)

    /// A settled three-finisher field, which clears `didRun`'s truncation floor.
    /// Below three finishers it returns nil and the tip stays unresolved — the
    /// guard doing its job, not a bug.
    private static func winner(_ horseID: String) -> RaceResult {
        var finishing = [(horseID, "1")]
        var position = 2
        for other in ["hrs_1", "hrs_2", "hrs_3"] where other != horseID {
            finishing.append((other, String(position)))
            position += 1
        }
        return TestResult.result(finishing: finishing)
    }

    func test_aBetfairPriceReachesTheOutcome() throws {
        let reference = MarketReference.make()
        let tip = TipRecord.make(selection: "hrs_1", marketReference: reference)
        let prices = reference.startingPrices(
            from: ["1.100": [MarketReference.selectionID(at: 0): 4.8]])

        let settled = ResultReconciler.settle(
            tip: tip,
            result: Self.winner("hrs_1"),
            betfairStartingPrices: prices,
            now: Self.afterwards)

        XCTAssertTrue(try XCTUnwrap(settled.outcome).isWin)
        XCTAssertEqual(settled.outcome?.betfairSP, 4.8)
    }

    func test_aLoserKeepsItsPriceToo() throws {
        // The losing price is not used for the payout, but the count of tips
        // *with* a price is the ROI denominator — so dropping it on losers would
        // report ROI over winners only, which is not a number at all.
        let reference = MarketReference.make()
        let tip = TipRecord.make(selection: "hrs_2", marketReference: reference)
        let prices = reference.startingPrices(
            from: ["1.100": [MarketReference.selectionID(at: 1): 9.2]])

        let settled = ResultReconciler.settle(
            tip: tip,
            result: Self.winner("hrs_1"),
            betfairStartingPrices: prices,
            now: Self.afterwards)

        XCTAssertEqual(settled.outcome?.isWin, false)
        XCTAssertEqual(settled.outcome?.betfairSP, 9.2)
    }

    func test_theFavouriteBaselineIsPricedFromTheSameReference() throws {
        // The baseline is the most valuable number in the app. If the tip could
        // be priced and the favourite could not, every ROI comparison would
        // flatter the model by construction.
        let reference = MarketReference.make()
        let tip = TipRecord.make(
            selection: "hrs_2",
            marketFavouriteHorseID: "hrs_1",
            agreedWithFavourite: false,
            marketReference: reference)
        let prices = reference.startingPrices(from: ["1.100": [
            MarketReference.selectionID(at: 0): 2.4,
            MarketReference.selectionID(at: 1): 9.2,
        ]])

        let settled = ResultReconciler.settle(
            tip: tip,
            result: Self.winner("hrs_1"),
            betfairStartingPrices: prices,
            now: Self.afterwards)

        let favourite = try XCTUnwrap(settled.favouriteOutcome)
        XCTAssertEqual(favourite.horseID, "hrs_1")
        XCTAssertTrue(favourite.won)
        XCTAssertEqual(favourite.betfairSP, 2.4)
    }

    func test_noBetfairPriceStillSettlesTheTip() throws {
        // Betfair absent, unmatched, or the market not yet settled. The result
        // alone decides won or lost; only the ROI figure is lost, and the report
        // counts those separately rather than hiding them.
        let tip = TipRecord.make(selection: "hrs_1", marketReference: nil)

        let settled = ResultReconciler.settle(
            tip: tip,
            result: Self.winner("hrs_1"),
            now: Self.afterwards)

        XCTAssertTrue(try XCTUnwrap(settled.outcome).isWin)
        XCTAssertNil(settled.outcome?.betfairSP)
    }

    // MARK: - Which markets to ask about

    func test_onlySettleableTipsWithAReferenceAreAskedFor() {
        // Settled already: excluded because `awaitingReconciliation` drops
        // anything with a final outcome, which is also what stops a BSP we
        // already hold being re-requested.
        let settled = TipRecord.make(
            raceID: "settled",
            offAt: Self.off,
            marketReference: .make(marketID: "1.settled"),
            outcome: .won(betfairSP: 4.0))
        // Still open, and the market is known.
        let open = TipRecord.make(
            raceID: "open",
            offAt: Self.off,
            marketReference: .make(marketID: "1.open"),
            outcome: .unresolved(lastCheckedAt: Self.off, attempts: 1))
        // Open, but no market ever matched — nothing to ask about.
        let unmatched = TipRecord.make(
            raceID: "unmatched", offAt: Self.off, marketReference: nil)
        // Given up on. Asking would spend a request on a tip excluded from
        // every metric anyway.
        let expired = TipRecord.make(
            raceID: "expired",
            offAt: Self.off,
            marketReference: .make(marketID: "1.expired"),
            outcome: .expired(at: Self.off))
        let ledger = TipLedger(tips: [settled, open, unmatched, expired])

        let ids = ledger.marketIDsAwaitingStartingPrice(now: Self.afterwards)

        XCTAssertEqual(ids, ["1.open"])
    }

    func test_aRaceThatHasNotRunIsNotAskedFor() {
        let tip = TipRecord.make(offAt: Self.off, marketReference: .make())
        let ledger = TipLedger(tips: [tip])

        // Half an hour before the off. There is no starting price to have.
        let ids = ledger.marketIDsAwaitingStartingPrice(
            now: Self.off.addingTimeInterval(-1_800))

        XCTAssertTrue(ids.isEmpty)
    }

    func test_oneMarketIsAskedForOnceEvenWithSeveralTipsOnIt() {
        // Defensive rather than expected — one market per race — but a repeated
        // id would waste a slot in Betfair's forty-market batch.
        let first = TipRecord.make(
            raceID: "a", offAt: Self.off, marketReference: .make(marketID: "1.same"))
        let second = TipRecord.make(
            raceID: "b", offAt: Self.off, marketReference: .make(marketID: "1.same"))
        let ledger = TipLedger(tips: [first, second])

        XCTAssertEqual(
            ledger.marketIDsAwaitingStartingPrice(now: Self.afterwards), ["1.same"])
    }

    // MARK: - Persistence

    func test_theReferenceSurvivesTheLedgerRoundTrip() throws {
        let tip = TipRecord.make(marketReference: .make(marketID: "1.577"))
        let ledger = TipLedger(tips: [tip])

        let encoded = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(TipLedger.self, from: encoded)

        let restored = try XCTUnwrap(decoded.tip(forRace: tip.raceID))
        XCTAssertEqual(restored.marketReference?.marketID, "1.577")
        XCTAssertEqual(restored.marketReference, tip.marketReference)
    }

    func test_aTipStoredBeforeThisFieldExistedStillDecodes() throws {
        // The field is additive on purpose. A ledger that failed to decode would
        // discard the entire accuracy record — the one thing in the app that
        // cannot be regenerated, because the free results endpoint is today-only.
        // Encode a tip that *has* a reference, then strip the key — a nil
        // optional is omitted by the synthesised encoder anyway, so starting
        // from a nil one would prove nothing.
        let tip = TipRecord.make(marketReference: .make())
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(tip)) as? [String: Any])
        XCTAssertNotNil(json["marketReference"])
        json.removeValue(forKey: "marketReference")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(TipRecord.self, from: stripped)

        XCTAssertNil(decoded.marketReference)
        XCTAssertEqual(decoded.raceID, tip.raceID)
        XCTAssertEqual(decoded.selectionHorseID, tip.selectionHorseID)
    }
}
