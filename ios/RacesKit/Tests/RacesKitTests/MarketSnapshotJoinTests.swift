import XCTest
@testable import RacesKit

/// The one crossing between the exchange's identifiers and ours.
///
/// Worth its own suite because a price attached to the wrong horse looks
/// entirely normal in the output and is undetectable from it — the worst thing
/// this layer can do and the hardest to notice.
final class MarketSnapshotJoinTests: XCTestCase {

    private static let captured = Date(timeIntervalSince1970: 1_789_997_400)

    private func prices(
        marketID: String = "1.100",
        _ bySelection: [Int64: Double]
    ) -> ExchangeMarketPrices {
        ExchangeMarketPrices(
            marketID: marketID,
            status: "OPEN",
            capturedAt: Self.captured,
            isDelayed: true,
            prices: bySelection.mapValues { RunnerPrice(backPrice: $0) })
    }

    func test_pricesAreRekeyedOntoOurHorseIDs() {
        let snapshot = MarketSnapshot(
            joining: prices([10_001: 2.5, 10_002: 6.0]),
            horseIDsBySelectionID: [10_001: "hrs_a", 10_002: "hrs_b"])

        XCTAssertEqual(snapshot.marketID, "1.100")
        XCTAssertEqual(snapshot.capturedAt, Self.captured)
        XCTAssertTrue(snapshot.isDelayed)
        XCTAssertEqual(snapshot.price(for: "hrs_a")?.backPrice, 2.5)
        XCTAssertEqual(snapshot.price(for: "hrs_b")?.backPrice, 6.0)
    }

    func test_anUnmatchedSelectionIsDroppedRatherThanGuessedAt() {
        let snapshot = MarketSnapshot(
            joining: prices([10_001: 2.5, 10_099: 6.0]),
            horseIDsBySelectionID: [10_001: "hrs_a"])

        XCTAssertEqual(snapshot.prices.count, 1)
        XCTAssertEqual(snapshot.price(for: "hrs_a")?.backPrice, 2.5)
    }

    func test_aHorseWithNoPriceSimplyHasNone() {
        let snapshot = MarketSnapshot(
            joining: prices([10_001: 2.5]),
            horseIDsBySelectionID: [10_001: "hrs_a", 10_002: "hrs_b"])

        XCTAssertNil(snapshot.price(for: "hrs_b"))
        // Which is what `coverage(of:)` then reports to the rater, so a
        // half-priced book is discarded rather than anchoring half a field.
        let runners = [
            Runner(id: "hrs_a", name: "A", clothNumber: 1),
            Runner(id: "hrs_b", name: "B", clothNumber: 2),
        ]
        XCTAssertEqual(snapshot.coverage(of: runners), 0.5)
    }

    func test_theSourceIsCarriedThroughSoAForecastIsNotPassedOffAsLive() {
        let snapshot = MarketSnapshot(
            joining: prices([10_001: 2.5]),
            horseIDsBySelectionID: [10_001: "hrs_a"],
            source: .forecast)

        XCTAssertEqual(snapshot.source, .forecast)
    }

    // MARK: - Through a match

    func test_theJoinReadsThePairingsTheMatcherEstablished() throws {
        // Names the two providers spell differently, so the pairing is the only
        // thing that can connect them. The snapshot must not depend on the
        // names agreeing.
        let race = TestMatching.race(horses: ["Frankel", "Kyprios", "Baaeed"])
        let market = TestMatching.market(
            selections: ["1. Frankel", "Kyprios (IRE)", "Baaeed"])
        let report = RaceMatcher.match(races: [race], markets: [market])
        let match = try XCTUnwrap(report.matchesByRaceID[race.id])

        let snapshot = match.snapshot(
            from: prices([10_001: 2.0, 10_002: 4.0, 10_003: 8.0]))

        XCTAssertEqual(snapshot.price(for: race.runners[0].id)?.backPrice, 2.0)
        XCTAssertEqual(snapshot.price(for: race.runners[1].id)?.backPrice, 4.0)
        XCTAssertEqual(snapshot.price(for: race.runners[2].id)?.backPrice, 8.0)
        XCTAssertEqual(snapshot.coverage(of: race.declaredRunners), 1.0)
    }

    func test_aRunnerTheMatcherRefusedGetsNoPrice() throws {
        // Four of ours, three in the market. The fourth has no price, and that
        // is the correct outcome — inventing one would anchor it to whatever
        // selection happened to be spare.
        let race = TestMatching.race(horses: ["Frankel", "Kyprios", "Baaeed", "Enable"])
        let market = TestMatching.market(selections: ["Frankel", "Kyprios", "Baaeed"])
        let report = RaceMatcher.match(races: [race], markets: [market])
        let match = try XCTUnwrap(report.matchesByRaceID[race.id])

        let snapshot = match.snapshot(
            from: prices([10_001: 2.0, 10_002: 4.0, 10_003: 8.0]))

        XCTAssertNil(snapshot.price(for: race.runners[3].id))
        XCTAssertEqual(snapshot.coverage(of: race.declaredRunners), 0.75)
    }
}
