import XCTest
@testable import RacesKit

final class FormScorerTests: XCTestCase {

    private let scorer = FormScorer()

    private func score(_ form: String) throws -> Double {
        try XCTUnwrap(scorer.score(FormParser.parse(form)))
    }

    func test_unracedHorseHasNoScore() {
        XCTAssertNil(scorer.score(FormParser.parse(nil)))
        XCTAssertNil(scorer.score(FormParser.parse("")))
        XCTAssertNil(scorer.score(FormParser.parse("-/")), "gap markers alone are not runs")
    }

    func test_straightWinnerScoresTop() throws {
        XCTAssertEqual(try score("1"), 1.0, accuracy: 0.0001)
    }

    func test_alwaysUnplacedScoresBottom() throws {
        XCTAssertEqual(try score("PPP"), 0.0, accuracy: 0.0001)
    }

    func test_betterFinishesScoreHigher() throws {
        XCTAssertGreaterThan(try score("111"), try score("222"))
        XCTAssertGreaterThan(try score("222"), try score("555"))
        XCTAssertGreaterThan(try score("555"), try score("000"))
        XCTAssertGreaterThan(try score("000"), try score("PPP"))
    }

    /// Recency weighting: the same runs in the other order should not score the
    /// same, and the horse that just won should come out ahead.
    func test_recentRunsCountForMore() throws {
        let improving = try score("551")
        let declining = try score("155")

        XCTAssertGreaterThan(improving, declining)
    }

    /// A break reduces how much the runs *before* it count — it is not a penalty
    /// in itself. So its effect depends on what that older form was.
    ///
    /// Worth being precise about, because the intuitive reading ("a layoff is bad")
    /// is wrong here, and the honest one is that a layoff makes old evidence less
    /// relevant. How long a horse has actually been off is a separate factor
    /// (`daysSinceLastRun`); having the scorer punish it too would double-count.
    func test_aBreakReducesTheInfluenceOfOlderRuns() throws {
        // Good old form, poor recent run: discounting the good runs lowers the score.
        XCTAssertLessThan(try score("11/5"), try score("115"))

        // Poor old form, recent win: discounting the poor runs raises it.
        XCTAssertGreaterThan(try score("55/1"), try score("551"))
    }

    /// A long break discounts older runs harder than a season break does, so the
    /// gap between the two widens in whichever direction the older form points.
    func test_aLongBreakDiscountsHarderThanASeasonBreak() throws {
        XCTAssertLessThan(try score("11/5"), try score("11-5"))
        XCTAssertGreaterThan(try score("55/1"), try score("55-1"))
    }

    /// With every run scoring the same there is nothing for a break to reweight,
    /// so the score is unchanged. Falls out of using a weighted average.
    func test_aBreakChangesNothingWhenEveryRunIsIdentical() throws {
        XCTAssertEqual(try score("11/1"), try score("111"), accuracy: 0.0001)
    }

    func test_scoreStaysInRange() throws {
        for form in ["1", "9", "0", "P", "1-3241", "P/24F", "123456789", "0-0"] {
            let value = try score(form)
            XCTAssertGreaterThanOrEqual(value, 0, form)
            XCTAssertLessThanOrEqual(value, 1, form)
        }
    }

    /// A weighted average, not a sum, so a lightly-raced horse is not punished
    /// merely for having run less often.
    func test_aShortRecordIsNotPenalisedForItsLength() throws {
        XCTAssertEqual(try score("1"), try score("111"), accuracy: 0.0001)
    }

    func test_onlyTheMostRecentRunsAreConsidered() throws {
        let scorer = FormScorer(maxRuns: 2)
        let line = FormParser.parse("PPP11")

        // Only the trailing "11" is in scope, so this should score as a pair of wins.
        XCTAssertEqual(try XCTUnwrap(scorer.score(line)), 1.0, accuracy: 0.0001)
    }

    /// A voided race says nothing about the horse, so it is skipped rather than
    /// scored as a failure.
    func test_voidedRunsAreIgnoredNotPunished() throws {
        XCTAssertEqual(try score("1V1"), try score("11"), accuracy: 0.0001)
    }

    func test_pointsAreTunable() throws {
        let generous = FormScorer(points: ["1": 1.0, "2": 1.0, "nonCompletion": 0])
        let line = FormParser.parse("22")
        XCTAssertEqual(try XCTUnwrap(generous.score(line)), 1.0, accuracy: 0.0001)
    }
}
