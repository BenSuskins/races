import XCTest
@testable import RacesKit

final class StandardiserTests: XCTestCase {

    func test_producesZeroMeanScores() {
        let z = Standardiser.zScores([1, 2, 3, 4, 5])
        XCTAssertEqual(z.reduce(0, +), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(z[4], z[0])
    }

    func test_preservesOrdering() {
        let z = Standardiser.zScores([10, 50, 30])
        XCTAssertGreaterThan(z[1], z[2])
        XCTAssertGreaterThan(z[2], z[0])
    }

    /// The rule that protects every first-time runner: a missing value is
    /// race-neutral, not the bottom of the field.
    func test_missingValuesAreNeutralNotWorst() {
        let z = Standardiser.zScores([10, nil, 50])

        XCTAssertEqual(z[1], 0, "unknown is average, not worst")
        XCTAssertLessThan(z[0], z[1], "the genuinely low value is below neutral")
        XCTAssertGreaterThan(z[2], z[1])
    }

    /// A factor that cannot discriminate should contribute nothing rather than
    /// amplifying floating-point noise into a selection.
    func test_identicalValuesAllScoreZero() {
        XCTAssertEqual(Standardiser.zScores([7, 7, 7, 7]), [0, 0, 0, 0])
    }

    func test_tooFewValuesToCompareScoreZero() {
        XCTAssertEqual(Standardiser.zScores([nil, nil, nil]), [0, 0, 0])
        XCTAssertEqual(Standardiser.zScores([5, nil, nil]), [0, 0, 0])
        XCTAssertEqual(Standardiser.zScores([]), [])
    }

    /// One freak value must not be allowed to dominate a race.
    func test_clipping() {
        let z = Standardiser.zScores([1, 1, 1, 1, 1, 1, 1, 1, 1, 1000], clip: 2.0)
        XCTAssertEqual(z[9], 2.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(z.min() ?? 0, -2.0)
    }

    func test_nonFiniteValuesAreTreatedAsMissing() {
        let z = Standardiser.zScores([1, 2, .nan, 3])
        XCTAssertEqual(z[2], 0)
        XCTAssertTrue(z.allSatisfy(\.isFinite))
    }
}
