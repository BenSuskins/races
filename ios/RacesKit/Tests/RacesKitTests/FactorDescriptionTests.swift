import XCTest
@testable import RacesKit

/// The pairing between a factor, its weight and the text explaining it.
///
/// These live on the Linux side deliberately. The Model screen is the app's
/// answer to "why does it fancy that one?", and the failure mode is silent: add
/// a factor, forget the copy, and the screen shows a weight with no explanation
/// beside it. Nothing about that looks broken.
final class FactorDescriptionTests: XCTestCase {

    func test_everyFactorHasASummary() {
        for factor in FactorID.allCases {
            XCTAssertFalse(
                factor.summary.isEmpty,
                "\(factor.rawValue) has no summary, so the Model screen would show a bare number")
            XCTAssertFalse(factor.label.isEmpty, "\(factor.rawValue) has no label")
        }
    }

    /// A factor shipped at zero weight needs a reason, or the zero reads as an
    /// oversight rather than a decision. This is the assertion that stops a new
    /// switched-off factor going in unexplained.
    func test_everyZeroWeightedFactorInV1ExplainsItself() {
        let weights = RatingWeights.v1

        for factor in FactorID.allCases where weights.weight(for: factor) == 0 {
            XCTAssertNotNil(
                factor.rationale,
                "\(factor.rawValue) ships at zero weight with no rationale")
        }
    }

    func test_v1HasAWeightForEveryFactorItKnowsAbout() {
        let weights = RatingWeights.v1

        // A factor absent from the dictionary contributes nothing, which is the
        // same behaviour as an explicit zero and none of the visibility. The
        // Model screen would list it at 0.00 with no rationale, and the reader
        // could not tell "decided against" from "forgotten".
        for factor in FactorID.allCases {
            XCTAssertNotNil(
                weights.factorWeights[factor.rawValue],
                "\(factor.rawValue) is missing from RatingWeights.v1")
        }
    }

    func test_theDeliberateZerosAreExactlyTheOnesDocumented() {
        let weights = RatingWeights.v1
        let zeroed = Set(FactorID.allCases.filter { weights.weight(for: $0) == 0 })

        // Pinned, so switching one on is a visible decision rather than a
        // side effect. `weightCarried` is near zero and deliberately not zero.
        XCTAssertEqual(zeroed, [.draw, .headgear, .jockeyStrikeRate, .trainerStrikeRate, .jockeySurfaceStrikeRate, .trainerSurfaceStrikeRate])
        XCTAssertGreaterThan(weights.weight(for: .weightCarried), 0)
    }

    func test_weightsSumToSomethingSaneSoNoSingleFactorDominates() {
        let weights = RatingWeights.v1
        let total = FactorID.allCases.reduce(0) { $0 + weights.weight(for: $1) }

        XCTAssertEqual(total, 1.05, accuracy: 0.0001)
        // The heaviest factor is the official rating, and it is under a third.
        // Not a law of nature, but a sanity check: the free tier's strongest
        // signal should lead without being the whole model.
        let heaviest = FactorID.allCases.map { weights.weight(for: $0) }.max() ?? 0
        XCTAssertEqual(heaviest, weights.weight(for: .officialRating))
        XCTAssertLessThan(heaviest, 0.5)
    }

    func test_theControlConfigurationCarriesNoFactorsAtAll() {
        let weights = RatingWeights.marketOnly

        // The back-test's control: β = 0 and nothing weighted, so the output is
        // the market and "does any of this help?" becomes measurable.
        XCTAssertEqual(weights.formInfluence, 0)
        XCTAssertEqual(weights.formInfluenceNoMarket, 0)
        for factor in FactorID.allCases {
            XCTAssertEqual(weights.weight(for: factor), 0)
        }
    }
}
