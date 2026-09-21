import XCTest
@testable import RacesKit

final class FormLineTests: XCTestCase {

    // MARK: - Ordering

    /// **The test that matters most in this file.** UK convention puts the most
    /// recent run on the right. Reading it backwards would silently invert the
    /// strongest form signal on the free tier, and nothing else about the output
    /// would look wrong.
    func test_mostRecentRunIsTheRightmostCharacter() {
        let line = FormParser.parse("1-3241")

        XCTAssertEqual(line.lastRun, .finished(1), "the trailing 1 is the latest run")
        XCTAssertEqual(line.wonLastTime, true)
        XCTAssertEqual(line.runs.first, .finished(1), "the leading 1 is the oldest run")
    }

    func test_outcomesAreOldestFirst() {
        let line = FormParser.parse("123")
        XCTAssertEqual(line.outcomes, [.finished(1), .finished(2), .finished(3)])
        XCTAssertEqual(line.lastRun, .finished(3))
        XCTAssertEqual(line.wonLastTime, false)
    }

    // MARK: - Characters

    func test_digitsAreFinishingPositions() {
        XCTAssertEqual(FormParser.parse("123456789").runs.count, 9)
        XCTAssertEqual(FormParser.parse("5").lastRun, .finished(5))
    }

    /// `0` means tenth or worse, not "position zero".
    func test_zeroMeansTenthOrWorse() {
        XCTAssertEqual(FormParser.parse("0").lastRun, .finished(10))
    }

    func test_nonCompletionLetters() {
        let cases: [(String, FormOutcome)] = [
            ("P", .pulledUp), ("U", .unseatedRider), ("F", .fell), ("R", .refused),
            ("B", .broughtDown), ("S", .slippedUp), ("D", .disqualified), ("V", .voided),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(FormParser.parse(raw).lastRun, expected, raw)
        }
    }

    func test_lowercaseLettersParseToo() {
        XCTAssertEqual(FormParser.parse("pu").runs, [.pulledUp, .unseatedRider])
    }

    func test_breaksAreMarkersNotRuns() {
        let line = FormParser.parse("12-34")

        XCTAssertEqual(line.runCount, 4, "the hyphen is not a run")
        XCTAssertTrue(line.outcomes.contains(.seasonBreak))
        XCTAssertFalse(line.hasLongBreak)

        let longBreak = FormParser.parse("3/12")
        XCTAssertTrue(longBreak.hasLongBreak)
        XCTAssertEqual(longBreak.runCount, 3)
    }

    // MARK: - Totality

    /// A novel character in one horse's form must not cost us the racecard.
    func test_parsingIsTotal() {
        XCTAssertTrue(FormParser.parse(nil).isEmpty)
        XCTAssertTrue(FormParser.parse("").isEmpty)
        XCTAssertTrue(FormParser.parse("   ").isEmpty)

        let odd = FormParser.parse("1X2")
        XCTAssertEqual(odd.runCount, 2, "the unrecognised character is not counted as a run")
        XCTAssertTrue(odd.outcomes.contains(.unrecognised("X")))
    }

    func test_unracedHorseHasNoOpinion() {
        let line = FormParser.parse(nil)
        XCTAssertNil(line.wonLastTime)
        XCTAssertNil(line.completionRate)
        XCTAssertNil(line.lastRun)
    }

    // MARK: - Derived

    func test_completionRate() {
        XCTAssertEqual(FormParser.parse("1234").completionRate, 1.0)
        XCTAssertEqual(try XCTUnwrap(FormParser.parse("12PU").completionRate), 0.5, accuracy: 0.0001)
        XCTAssertEqual(FormParser.parse("PPFU").completionRate, 0.0)
    }

    func test_completionRateIgnoresBreakMarkers() throws {
        let rate = try XCTUnwrap(FormParser.parse("1-2/P").completionRate)
        XCTAssertEqual(rate, 2.0 / 3.0, accuracy: 0.0001)
    }
}
