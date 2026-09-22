import XCTest
@testable import RacesKit

final class BetfairMappingTests: XCTestCase {

    private func catalogues() throws -> [BetfairMarketCatalogue] {
        try Fixture.decode([BetfairMarketCatalogue].self, from: "betfair-listmarketcatalogue.json")
    }

    // MARK: - Cloth numbers, the join key

    func test_clothNumberIsParsedFromItsStringMetadata() {
        // Every metadata value arrives as a string, including the numeric ones.
        XCTAssertEqual(BetfairMapping.clothNumber(from: ["CLOTH_NUMBER": "7"]), 7)
    }

    func test_aZeroClothNumberIsTreatedAsAbsent() {
        // Betfair sends "0" on markets where the numbers are not published.
        // Treating it as a real cloth number would have the matcher join on a
        // value every such runner shares — and cloth numbers are the primary
        // join key, so that is the worst possible place to be wrong.
        XCTAssertNil(BetfairMapping.clothNumber(from: ["CLOTH_NUMBER": "0"]))
    }

    func test_aBlankOrMissingClothNumberIsAbsent() {
        XCTAssertNil(BetfairMapping.clothNumber(from: ["CLOTH_NUMBER": ""]))
        XCTAssertNil(BetfairMapping.clothNumber(from: ["CLOTH_NUMBER": "  "]))
        XCTAssertNil(BetfairMapping.clothNumber(from: ["JOCKEY_NAME": "R Moore"]))
        XCTAssertNil(BetfairMapping.clothNumber(from: nil))
    }

    func test_aNonNumericClothNumberIsAbsentRatherThanCrashing() {
        XCTAssertNil(BetfairMapping.clothNumber(from: ["CLOTH_NUMBER": "n/a"]))
    }

    // MARK: - Markets

    func test_runnerNamesKeepTheirDecorationForTheNormaliserToStrip() throws {
        let market = try XCTUnwrap(BetfairMapping.exchangeMarket(from: try catalogues()[0]))

        // `HorseNameNormaliser` strips the cloth prefix and the country suffix.
        // Doing it here too would mean two places to keep in step.
        XCTAssertEqual(market.runners.first?.name, "1. Kyprios (IRE)")
    }

    func test_removedRunnersAreCarriedButInactive() throws {
        let market = try XCTUnwrap(BetfairMapping.exchangeMarket(from: try catalogues()[0]))

        let removed = try XCTUnwrap(market.runners.first { $0.id == 32345678 })
        XCTAssertFalse(removed.isActive)
        // `activeRunners` is what matching uses: counting a withdrawn runner
        // would drag the overlap check down for a race that matched perfectly.
        XCTAssertFalse(market.activeRunners.contains { $0.id == 32345678 })
        XCTAssertEqual(market.activeRunners.count, 3)
    }

    func test_theVenueIsTakenFromTheEvent() throws {
        let market = try XCTUnwrap(BetfairMapping.exchangeMarket(from: try catalogues()[0]))
        XCTAssertEqual(market.venue, "Ascot")
    }

    func test_theStartTimeIsParsedWithFractionalSeconds() throws {
        let market = try XCTUnwrap(BetfairMapping.exchangeMarket(from: try catalogues()[0]))

        // Betfair sends `2026-09-22T13:45:00.000Z`. A parser without the
        // fractional-seconds option returns nil and the market is dropped.
        let expected = RaceDates.iso8601WithFractionalSeconds
            .date(from: "2026-09-22T13:45:00.000Z")
        XCTAssertEqual(market.startTime, try XCTUnwrap(expected))
    }

    func test_aMarketWithNoStartTimeMapsToNil() throws {
        XCTAssertNil(BetfairMapping.exchangeMarket(from: try catalogues()[2]))
    }

    // MARK: - Snapshot join

    func test_snapshotKeysPricesByOurHorseID() throws {
        let prices = ExchangeMarketPrices(
            marketID: "1.1",
            prices: [
                12345678: RunnerPrice(backPrice: 2.4),
                22345678: RunnerPrice(backPrice: 4.8),
            ])

        let snapshot = BetfairMapping.snapshot(
            from: prices,
            horseIDsBySelectionID: [12345678: "hrs_a", 22345678: "hrs_b"])

        XCTAssertEqual(try XCTUnwrap(snapshot.price(for: "hrs_a")?.backPrice), 2.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.price(for: "hrs_b")?.backPrice), 4.8, accuracy: 0.0001)
    }

    func test_anUnmatchedSelectionIsDroppedNotGuessedAt() throws {
        let prices = ExchangeMarketPrices(
            marketID: "1.1",
            prices: [
                12345678: RunnerPrice(backPrice: 2.4),
                99999999: RunnerPrice(backPrice: 100.0),
            ])

        let snapshot = BetfairMapping.snapshot(
            from: prices,
            horseIDsBySelectionID: [12345678: "hrs_a"])

        // A price attached to the wrong horse looks entirely normal and silently
        // anchors the model to another animal. Dropping is the only safe answer.
        XCTAssertEqual(snapshot.prices.count, 1)
        XCTAssertNotNil(snapshot.price(for: "hrs_a"))
    }

    func test_theSnapshotCarriesTheDelayFlagThrough() throws {
        let prices = ExchangeMarketPrices(
            marketID: "1.1", isDelayed: true, prices: [1: RunnerPrice(backPrice: 2.0)])

        let snapshot = BetfairMapping.snapshot(
            from: prices, horseIDsBySelectionID: [1: "hrs_a"])

        // "Live exchange, delayed three minutes" deserves saying out loud
        // wherever a price is shown.
        XCTAssertTrue(snapshot.isDelayed)
    }

    // MARK: - Error codes

    func test_knownFaultCodesMapToTheRightAPIError() {
        XCTAssertEqual(BetfairErrorCode(rawValue: "INVALID_SESSION_INFORMATION").asAPIError, .unauthorized)
        XCTAssertEqual(BetfairErrorCode(rawValue: "NO_SESSION").asAPIError, .unauthorized)
        XCTAssertEqual(BetfairErrorCode(rawValue: "INVALID_APP_KEY").asAPIError, .forbidden)
        XCTAssertEqual(BetfairErrorCode(rawValue: "ACCESS_DENIED").asAPIError, .forbidden)
        XCTAssertEqual(BetfairErrorCode(rawValue: "TIMEOUT").asAPIError, .timedOut)
        XCTAssertEqual(
            BetfairErrorCode(rawValue: "TOO_MANY_REQUESTS").asAPIError,
            .rateLimited(retryAfter: nil))
    }

    func test_onlyAnInvalidSessionIsWorthSigningInAgainFor() {
        XCTAssertTrue(BetfairErrorCode(rawValue: "INVALID_SESSION_INFORMATION").isRecoverableBySigningInAgain)
        // Re-authenticating cannot fix a wrong app key, and looping on it would
        // hammer the exchange.
        XCTAssertFalse(BetfairErrorCode(rawValue: "INVALID_APP_KEY").isRecoverableBySigningInAgain)
        XCTAssertFalse(BetfairErrorCode(rawValue: "TOO_MUCH_DATA").isRecoverableBySigningInAgain)
    }

    func test_anUnknownCodeKeepsItsRawValue() {
        let code = BetfairErrorCode(rawValue: "BRAND_NEW_FAULT")
        XCTAssertEqual(code, .other("BRAND_NEW_FAULT"))
        XCTAssertEqual(code.rawCode, "BRAND_NEW_FAULT")
    }
}
