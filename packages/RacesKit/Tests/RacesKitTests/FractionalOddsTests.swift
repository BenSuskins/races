import XCTest
@testable import RacesKit

final class FractionalOddsTests: XCTestCase {

    func test_pricesOnTheLadderConvertExactly() {
        XCTAssertEqual(FractionalOdds.display(decimal: 9.0), "8/1")
        XCTAssertEqual(FractionalOdds.display(decimal: 3.5), "5/2")
        XCTAssertEqual(FractionalOdds.display(decimal: 2.1), "11/10")
        XCTAssertEqual(FractionalOdds.display(decimal: 1.5), "1/2")
    }

    func test_evenMoneyReadsAsEvens() {
        XCTAssertEqual(FractionalOdds.display(decimal: 2.0), "Evens")
    }

    /// The board prints 4/6 and 10/11, not 2/3 and a reduced fraction.
    func test_oddsOnPricesUseTheBoardsSpelling() {
        XCTAssertEqual(FractionalOdds.display(decimal: 1.67), "4/6")
        XCTAssertEqual(FractionalOdds.display(decimal: 1.91), "10/11")
    }

    /// Betfair's own steps sit between the traditional ones.
    func test_exchangePricesSnapToTheNearestStep() {
        XCTAssertEqual(FractionalOdds.display(decimal: 3.45), "5/2")
        XCTAssertEqual(FractionalOdds.display(decimal: 7.8), "7/1")
        XCTAssertEqual(FractionalOdds.display(decimal: 13.5), "12/1")
    }

    func test_pricesBeyondTheLadderClampToItsEnds() {
        XCTAssertEqual(FractionalOdds.display(decimal: 1500), "1000/1")
        XCTAssertEqual(FractionalOdds.display(decimal: 1.01), "1/50")
    }

    func test_somethingThatIsNotAPriceHasNoDisplay() {
        XCTAssertNil(FractionalOdds.display(decimal: 1.0))
        XCTAssertNil(FractionalOdds.display(decimal: 0.5))
        XCTAssertNil(FractionalOdds.display(decimal: .infinity))
        XCTAssertNil(FractionalOdds.display(decimal: .nan))
    }

    func test_theLadderIsInOrder() {
        let values = FractionalOdds.ladder.map { Double($0.numerator) / Double($0.denominator) }
        XCTAssertEqual(values, values.sorted())
    }
}
