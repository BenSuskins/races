import XCTest
@testable import Races

final class RatingContextTests: XCTestCase {

    func test_ranksHighestFirst() {
        XCTAssertEqual(RatingContext.rank(90, among: [90, 80, 70])?.position, 1)
        XCTAssertEqual(RatingContext.rank(80, among: [90, 80, 70])?.position, 2)
        XCTAssertEqual(RatingContext.rank(70, among: [90, 80, 70])?.position, 3)
    }

    func test_ordersIndependentlyOfTheInputOrder() {
        // The caller hands over marks in racecard order, not sorted.
        XCTAssertEqual(RatingContext.rank(80, among: [70, 90, 80])?.position, 2)
    }

    func test_tiedMarksShareAPosition() {
        // Nothing in the data breaks the tie, so inventing an order would be a
        // fabricated ranking presented as fact.
        XCTAssertEqual(RatingContext.rank(80, among: [80, 80, 70])?.position, 1)
        XCTAssertEqual(RatingContext.rank(70, among: [80, 80, 70])?.position, 3)
    }

    func test_nothingToCompareAgainstYieldsNoClaim() {
        XCTAssertNil(RatingContext.rank(80, among: [80]))
        XCTAssertNil(RatingContext.rank(80, among: []))
    }

    func test_aMarkNotInTheFieldIsRefused() {
        // Guards against a caller passing a filtered list that excludes the runner.
        XCTAssertNil(RatingContext.rank(85, among: [90, 80]))
    }

    func test_describesTopRated() {
        XCTAssertEqual(RatingContext.describe(90, among: [90, 80, 70]), "Top-rated of 3")
    }

    func test_describesJointTopRated() {
        XCTAssertEqual(
            RatingContext.describe(90, among: [90, 90, 70]),
            "Joint top-rated of 3")
    }

    func test_describesAPlacing() {
        XCTAssertEqual(RatingContext.describe(80, among: [90, 80, 70]), "2nd of 3 rated")
    }

    func test_ordinalsHandleTheTeens() {
        // 11, 12 and 13 are what a bare `% 10` gets wrong, and field sizes reach
        // them routinely.
        XCTAssertEqual(RatingContext.ordinal(11), "11th")
        XCTAssertEqual(RatingContext.ordinal(12), "12th")
        XCTAssertEqual(RatingContext.ordinal(13), "13th")
        XCTAssertEqual(RatingContext.ordinal(21), "21st")
        XCTAssertEqual(RatingContext.ordinal(22), "22nd")
        XCTAssertEqual(RatingContext.ordinal(23), "23rd")
    }

    func test_ordinalsHandleTheSmallNumbersThatActuallyOccur() {
        XCTAssertEqual(RatingContext.ordinal(1), "1st")
        XCTAssertEqual(RatingContext.ordinal(2), "2nd")
        XCTAssertEqual(RatingContext.ordinal(3), "3rd")
        XCTAssertEqual(RatingContext.ordinal(4), "4th")
    }
}
