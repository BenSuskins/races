import XCTest
@testable import RacesKit

/// Pins the Swift rater to the Go one that replaced it on the server.
///
/// `server/internal/parity` rates `racingapi-racecards-free.json` under every
/// preset, with and without a market, and commits the numbers as
/// `server-golden-rating.json`. This rates the same fixture here and asserts
/// the same numbers. While both raters exist, neither can drift: a changed
/// weight or factor on one side fails this test until the other matches and
/// the golden file is regenerated (`go test ./internal/parity -update`).
///
/// When the Swift rater is deleted, this test goes with it.
final class ServerParityTests: XCTestCase {

    private struct Golden: Decodable {
        struct Runner: Decodable {
            let horseID: String
            let winProbability: Double
            let formScore: Double
            let marketProbability: Double?
        }
        struct Case: Decodable {
            let raceID: String
            let weightsID: String
            let withMarket: Bool
            let selectionID: String
            let confidence: String
            let coverage: Double
            let runners: [Runner]
        }
        let cases: [Case]
    }

    /// The same market as `parity.Market()` in Go, by our horse id.
    private let markets: [String: [String: RunnerPrice]] = [
        "rac_1001": [
            "hrs_1": RunnerPrice(backPrice: 1.7, layPrice: 1.75),
            "hrs_2": RunnerPrice(backPrice: 3.4),
            "hrs_3": RunnerPrice(forecastPrice: 8.5),
            "hrs_4": RunnerPrice(backPrice: 19, layPrice: 21),
        ],
        "rac_1002": [
            "hrs_5": RunnerPrice(backPrice: 2.1),
            "hrs_6": RunnerPrice(lastTraded: 1.9),
        ],
    ]

    private let presets: [String: RatingWeights] = [
        RatingWeights.v1.id: .v1,
        RatingWeights.v2.id: .v2,
        RatingWeights.marketOnly.id: .marketOnly,
    ]

    func test_theSwiftRaterMatchesTheServersGoldenFile() throws {
        let golden = try Fixture.decode(Golden.self, from: "server-golden-rating.json")
        let page = try Fixture.decode(
            RacingAPIRacecardsPage.self,
            from: "racingapi-racecards-free.json",
            using: RacingAPIClient.decoder)
        let races = Dictionary(
            uniqueKeysWithValues: (page.racecards ?? [])
                .compactMap(RacingAPIMapping.race(from:))
                .map { ($0.id, $0) })

        XCTAssertEqual(golden.cases.count, 12, "three presets × two races × with and without a market")

        for expected in golden.cases {
            let label = "\(expected.raceID) \(expected.weightsID) market=\(expected.withMarket)"
            let race = try XCTUnwrap(races[expected.raceID], label)
            let weights = try XCTUnwrap(presets[expected.weightsID], label)
            let market = expected.withMarket
                ? MarketSnapshot(source: .liveExchange, isDelayed: true, prices: markets[race.id] ?? [:])
                : nil

            let assessment = RaceRater(weights: weights).rate(race, market: market, now: Date(timeIntervalSince1970: 0))

            XCTAssertEqual(assessment.selection?.horseID, expected.selectionID, label)
            XCTAssertEqual(assessment.confidence.rawValue, expected.confidence, label)
            XCTAssertEqual(assessment.marketCoverage, expected.coverage, accuracy: 1e-12, label)
            XCTAssertEqual(assessment.runners.map(\.horseID), expected.runners.map(\.horseID), label)
            for (actual, want) in zip(assessment.runners, expected.runners) {
                XCTAssertEqual(actual.winProbability, want.winProbability, accuracy: 1e-9, "\(label) \(want.horseID)")
                XCTAssertEqual(actual.formScore, want.formScore, accuracy: 1e-9, "\(label) \(want.horseID)")
                XCTAssertEqual(actual.marketProbability == nil, want.marketProbability == nil, "\(label) \(want.horseID)")
                if let a = actual.marketProbability, let w = want.marketProbability {
                    XCTAssertEqual(a, w, accuracy: 1e-9, "\(label) \(want.horseID)")
                }
            }
        }
    }
}
