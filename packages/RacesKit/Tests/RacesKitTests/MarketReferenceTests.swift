import XCTest
@testable import RacesKit

/// The settlement half of the exchange join.
///
/// Its own suite because the failure is invisible in the output: a starting
/// price attributed to the wrong horse produces an ROI figure that looks
/// entirely ordinary and is simply false — and unlike a mispriced tip, there is
/// no screen anywhere that would contradict it.
final class MarketReferenceTests: XCTestCase {

    private let reference = MarketReference(
        marketID: "1.100",
        selectionIDsByHorseID: ["hrs_a": 10_001, "hrs_b": 10_002, "hrs_c": 10_003])

    func test_settledPricesAreRekeyedOntoOurHorseIDs() {
        let prices = reference.startingPrices(
            from: ["1.100": [10_001: 3.4, 10_002: 6.0, 10_003: 12.5]])

        XCTAssertEqual(prices, ["hrs_a": 3.4, "hrs_b": 6.0, "hrs_c": 12.5])
    }

    func test_anotherMarketsPricesAreIgnored() {
        // The reply covers every market asked for in one batch, so picking the
        // right one is this type's job. Reading the wrong market's book would
        // price a race off another race's result.
        let prices = reference.startingPrices(
            from: ["1.999": [10_001: 3.4], "1.100": [10_002: 6.0]])

        XCTAssertEqual(prices, ["hrs_b": 6.0])
    }

    func test_anUnknownSelectionIsDroppedRatherThanGuessedAt() {
        let prices = reference.startingPrices(
            from: ["1.100": [10_001: 3.4, 99_999: 7.0]])

        XCTAssertEqual(prices, ["hrs_a": 3.4])
    }

    func test_aPriceOfOneOrBelowIsNotAPrice() {
        // Decimal odds of 1.0 mean no stake is returned at all, and Betfair
        // sends 0 for an unsettled market. Either would read as a real price
        // and destroy the ROI it fed.
        let prices = reference.startingPrices(
            from: ["1.100": [10_001: 0, 10_002: 1.0, 10_003: 2.5]])

        XCTAssertEqual(prices, ["hrs_c": 2.5])
    }

    func test_anEmptyReplyGivesNoPricesRatherThanZeroes() {
        XCTAssertTrue(reference.startingPrices(from: [:]).isEmpty)
        XCTAssertTrue(reference.startingPrices(from: ["1.100": [:]]).isEmpty)
    }

    func test_itSurvivesARoundTripThroughJSON() throws {
        // It is persisted inside the tip ledger, which is the only copy of the
        // accuracy record. A type that fails to round-trip loses the ROI for
        // every tip already stored.
        let encoded = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(MarketReference.self, from: encoded)

        XCTAssertEqual(decoded, reference)

        // And the horse-id keying is what keeps the stored file readable:
        // a `[Int64: Double]` would encode as a flat alternating array.
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains("hrs_a"))
    }

    // MARK: - Built from a match

    func test_theReferenceComesFromThePairingsTheMatcherEstablished() throws {
        let race = TestMatching.race(horses: ["Frankel", "Kyprios", "Baaeed"])
        let market = TestMatching.market(
            selections: ["1. Frankel", "Kyprios (IRE)", "Baaeed"])
        let report = RaceMatcher.match(races: [race], markets: [market])
        let match = try XCTUnwrap(report.matchesByRaceID[race.id])

        let reference = match.reference()

        XCTAssertEqual(reference.marketID, market.id)
        XCTAssertEqual(reference.selectionID(forHorse: race.runners[0].id), 10_001)
        XCTAssertEqual(reference.selectionID(forHorse: race.runners[2].id), 10_003)
        XCTAssertEqual(reference.selectionIDsByHorseID.count, 3)
    }

    func test_aRunnerTheMatcherRefusedIsAbsentFromTheReference() throws {
        // Four of ours, three in the market. The fourth has no coordinate, so it
        // can never be handed someone else's starting price.
        let race = TestMatching.race(horses: ["Frankel", "Kyprios", "Baaeed", "Enable"])
        let market = TestMatching.market(selections: ["Frankel", "Kyprios", "Baaeed"])
        let report = RaceMatcher.match(races: [race], markets: [market])
        let match = try XCTUnwrap(report.matchesByRaceID[race.id])

        let reference = match.reference()

        XCTAssertEqual(reference.selectionIDsByHorseID.count, 3)
        XCTAssertNil(reference.selectionID(forHorse: race.runners[3].id))
    }

    /// The reference carries the whole field, not just the tipped horse — which
    /// is what lets the favourite baseline have a price too.
    func test_theFavouriteCanBePricedFromTheSameReference() {
        let prices = reference.startingPrices(
            from: ["1.100": [10_001: 3.4, 10_002: 2.1]])

        // Say the tip was hrs_a and the favourite hrs_b: both get a price from
        // one stored map. Storing only the selection would leave the benchmark
        // permanently priceless while the tip had a price — the most flattering
        // possible asymmetry.
        XCTAssertNotNil(prices["hrs_a"])
        XCTAssertNotNil(prices["hrs_b"])
    }
}
