import XCTest
@testable import Races
import RacesKit

final class FormDisplayTests: XCTestCase {

    /// The whole reason `FormDisplay` exists. UK form reads right-to-left in time,
    /// so a screen that labels one end "Latest" must reverse the string first.
    /// Getting this backwards inverts the strongest free-tier signal and nothing
    /// about the result looks wrong.
    func test_mostRecentFirstReversesTheString() {
        XCTAssertEqual(FormDisplay.mostRecentFirst("1-3241"), "1423-1")
    }

    func test_reversingTwiceIsTheOriginal() {
        for raw in ["1-3241", "P/24F", "0-0", "", "1"] {
            XCTAssertEqual(
                FormDisplay.mostRecentFirst(FormDisplay.mostRecentFirst(raw)),
                raw)
        }
    }

    func test_theLatestRunInTheDisplayMatchesTheParsedLastRun() throws {
        // Ties the display to the parser, so the two cannot drift apart.
        let line = FormParser.parse("1-3241")
        let lastRun = try XCTUnwrap(line.lastRun)

        XCTAssertEqual(FormDisplay.describe(lastRun), "Won")
        XCTAssertEqual(FormDisplay.mostRecentFirst("1-3241").first, "1")
    }

    func test_describesNonCompletions() {
        XCTAssertEqual(FormDisplay.describe(.pulledUp), "Pulled up")
        XCTAssertEqual(FormDisplay.describe(.fell), "Fell")
        XCTAssertEqual(FormDisplay.describe(.unseatedRider), "Unseated rider")
    }

    func test_tenthOrWorseIsNotPrintedAsATenthPlace() {
        // `0` in a form string means "well beaten", and the exact position is
        // unknown — so claiming tenth specifically would be inventing a fact.
        XCTAssertEqual(FormDisplay.describe(.finished(10)), "Tenth or worse")
    }

    func test_describesOrdinaryPlacings() {
        XCTAssertEqual(FormDisplay.describe(.finished(1)), "Won")
        XCTAssertEqual(FormDisplay.describe(.finished(2)), "Second")
        XCTAssertEqual(FormDisplay.describe(.finished(3)), "Third")
        XCTAssertEqual(FormDisplay.describe(.finished(4)), "4th")
    }
}
