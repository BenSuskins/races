import XCTest
@testable import RacesKit

final class AccuracyMetricsTests: XCTestCase {

    private func tip(
        _ id: String,
        outcome: TipOutcome?,
        probability: Double = 0.25,
        agreed: Bool? = nil,
        favourite: FavouriteOutcome? = nil
    ) -> TipRecord {
        .make(
            raceID: id,
            predictedProbability: probability,
            agreedWithFavourite: agreed,
            outcome: outcome,
            favouriteOutcome: favourite
        )
    }

    // MARK: - Denominators

    /// The heart of an honest record. A non-runner is a void bet; counting it as
    /// a loss would mark the model down for a race it had no part in. An expired
    /// tip is unknown, not a loss either — but it is counted and shown, so a
    /// record built from a biased subsample cannot pass as a complete one.
    func test_onlyWinsAndLossesCountTowardsStrikeRate() throws {
        let report = AccuracyCalculator.report(for: [
            tip("a", outcome: .won(betfairSP: 4.0)),
            tip("b", outcome: .lost(position: 3, betfairSP: 6.0)),
            tip("c", outcome: .nonRunner),
            tip("d", outcome: .abandoned),
            tip("e", outcome: .unresolved(lastCheckedAt: Date(), attempts: 2)),
            tip("f", outcome: .expired(at: Date())),
            tip("g", outcome: nil),
        ])

        XCTAssertEqual(report.total, 7)
        XCTAssertEqual(report.settled, 2, "only the win and the loss")
        XCTAssertEqual(report.wins, 1)
        XCTAssertEqual(report.voided, 2)
        XCTAssertEqual(report.unresolved, 1)
        XCTAssertEqual(report.expired, 1)
        XCTAssertEqual(report.pending, 1)
        XCTAssertEqual(try XCTUnwrap(report.strikeRate), 0.5, accuracy: 0.000001)
    }

    func test_coverageReportsHowMuchOfTheRecordWeActuallyKnow() throws {
        let report = AccuracyCalculator.report(for: [
            tip("a", outcome: .won(betfairSP: 4.0)),
            tip("b", outcome: .lost(position: 2, betfairSP: 4.0)),
            tip("c", outcome: .nonRunner),
            tip("d", outcome: .expired(at: Date())),
        ])

        // Three of the four finished races have a known outcome.
        XCTAssertEqual(report.coverage, 0.75, accuracy: 0.000001)
    }

    func test_anEmptyRecordReportsNothingRatherThanZero() {
        let report = AccuracyCalculator.report(for: [])

        XCTAssertNil(report.strikeRate, "no tips is not a 0% strike rate")
        XCTAssertNil(report.roi)
        XCTAssertNil(report.brierScore)
        XCTAssertEqual(report.coverage, 1)
    }

    // MARK: - ROI

    func test_roiToLevelStakesNetOfCommission() throws {
        // One winner at 5.0 and four losers. Net of 5% commission the winner
        // returns 1 + 4 × 0.95 = 4.80 on five points staked.
        var tips = [tip("win", outcome: .won(betfairSP: 5.0))]
        tips += (1...4).map { tip("lose\($0)", outcome: .lost(position: 3, betfairSP: 8.0)) }

        let report = AccuracyCalculator.report(for: tips, commission: 0.05)
        let roi = try XCTUnwrap(report.roi)

        XCTAssertEqual(roi.bets, 5)
        XCTAssertEqual(roi.staked, 5)
        XCTAssertEqual(roi.returned, 4.80, accuracy: 0.000001)
        XCTAssertEqual(roi.profit, -0.20, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(roi.percentage), -0.04, accuracy: 0.000001)
    }

    func test_zeroCommissionIsHonoured() throws {
        let report = AccuracyCalculator.report(
            for: [tip("win", outcome: .won(betfairSP: 5.0))], commission: 0
        )
        XCTAssertEqual(try XCTUnwrap(report.roi).returned, 5.0, accuracy: 0.000001)
    }

    /// Strike rate and ROI count different races, because ROI needs a price and
    /// many races will not have one. Blending the denominators is how tipping
    /// records quietly overstate themselves.
    func test_racesWithoutAPriceCountForStrikeRateButNotROI() throws {
        let report = AccuracyCalculator.report(for: [
            tip("priced", outcome: .won(betfairSP: 4.0)),
            tip("unpriced", outcome: .won(betfairSP: nil)),
            tip("lost", outcome: .lost(position: 2, betfairSP: nil)),
        ])

        XCTAssertEqual(report.settled, 3)
        XCTAssertEqual(try XCTUnwrap(report.strikeRate), 2.0 / 3.0, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(report.roi).bets, 1, "only the priced race")
        XCTAssertEqual(report.settledWithoutPrice, 2)
    }

    /// Level-stakes ROI over a handful of bets is noise, and showing it would
    /// invite exactly the wrong conclusion.
    func test_roiIsGatedBehindASampleWorthQuoting() {
        let few = (1...10).map { tip("r\($0)", outcome: .lost(position: 4, betfairSP: 5.0)) }
        XCTAssertFalse(AccuracyCalculator.report(for: few).isSufficientSampleForROI)

        let many = (1...AccuracyReport.minimumSampleForROI).map {
            tip("r\($0)", outcome: .lost(position: 4, betfairSP: 5.0))
        }
        XCTAssertTrue(AccuracyCalculator.report(for: many).isSufficientSampleForROI)
    }

    // MARK: - Calibration

    /// A model saying 25% and hitting 25% is working, even if the overround
    /// makes it unprofitable. Strike rate alone cannot tell you that.
    func test_calibrationComparesPredictedWithActual() throws {
        var tips = [tip("win", outcome: .won(betfairSP: 4.0), probability: 0.25)]
        tips += (1...3).map { tip("lose\($0)", outcome: .lost(position: 2, betfairSP: 4.0), probability: 0.25) }

        let report = AccuracyCalculator.report(for: tips)

        XCTAssertEqual(try XCTUnwrap(report.strikeRate), 0.25, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(report.expectedStrikeRate), 0.25, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(report.calibrationError), 0, accuracy: 0.000001)
    }

    func test_brierScoreRewardsConfidentCorrectness() throws {
        let sure = AccuracyCalculator.report(for: [tip("a", outcome: .won(betfairSP: 2.0), probability: 0.95)])
        let unsure = AccuracyCalculator.report(for: [tip("a", outcome: .won(betfairSP: 2.0), probability: 0.05)])

        XCTAssertLessThan(try XCTUnwrap(sure.brierScore), try XCTUnwrap(unsure.brierScore))
    }

    // MARK: - The favourite baseline

    /// The most valuable number in the app. A 50% strike rate sounds excellent
    /// until you learn the favourite won all of the same races.
    func test_theFavouriteBaselineIsMeasuredOverTheSameRaces() throws {
        let report = AccuracyCalculator.report(for: [
            tip("a", outcome: .won(betfairSP: 4.0), agreed: false,
                favourite: FavouriteOutcome(horseID: "fav", won: true, betfairSP: 2.0)),
            tip("b", outcome: .lost(position: 3, betfairSP: 8.0), agreed: false,
                favourite: FavouriteOutcome(horseID: "fav", won: true, betfairSP: 2.5)),
        ])

        XCTAssertEqual(try XCTUnwrap(report.strikeRate), 0.5, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(report.favouriteBaseline.strikeRate), 1.0, accuracy: 0.000001)
        XCTAssertEqual(report.beatsFavouriteOnStrikeRate, false, "the model lost to the favourite here")
    }

    func test_beatingTheFavouriteIsReportedPlainly() {
        let report = AccuracyCalculator.report(for: [
            tip("a", outcome: .won(betfairSP: 4.0),
                favourite: FavouriteOutcome(horseID: "fav", won: false, betfairSP: 2.0)),
        ])

        XCTAssertEqual(report.beatsFavouriteOnStrikeRate, true)
    }

    func test_thereIsNoBaselineWithoutFavouriteData() {
        let report = AccuracyCalculator.report(for: [tip("a", outcome: .won(betfairSP: 4.0))])

        XCTAssertEqual(report.favouriteBaseline, .empty)
        XCTAssertNil(report.beatsFavouriteOnStrikeRate)
    }

    // MARK: - Agree / disagree

    /// When the tip *was* the favourite, the model contributed nothing to that
    /// race. All of its actual information is in the subset where it disagreed,
    /// and that is where it earns or loses its keep.
    func test_theAgreeAndDisagreeSubsetsAreReportedSeparately() throws {
        let report = AccuracyCalculator.report(for: [
            tip("agree_win", outcome: .won(betfairSP: 2.0), agreed: true),
            tip("agree_lose", outcome: .lost(position: 2, betfairSP: 2.0), agreed: true),
            tip("disagree_win", outcome: .won(betfairSP: 9.0), agreed: false),
            tip("disagree_lose1", outcome: .lost(position: 4, betfairSP: 9.0), agreed: false),
            tip("disagree_lose2", outcome: .lost(position: 6, betfairSP: 9.0), agreed: false),
        ])

        XCTAssertEqual(report.whenAgreeingWithFavourite.settled, 2)
        XCTAssertEqual(try XCTUnwrap(report.whenAgreeingWithFavourite.strikeRate), 0.5, accuracy: 0.000001)

        XCTAssertEqual(report.whenDisagreeing.settled, 3)
        XCTAssertEqual(try XCTUnwrap(report.whenDisagreeing.strikeRate), 1.0 / 3.0, accuracy: 0.000001)

        // 9.0 winner, net of 5%: 1 + 8 × 0.95 = 8.60 over three points staked.
        let roi = try XCTUnwrap(report.whenDisagreeing.roi)
        XCTAssertEqual(roi.returned, 8.60, accuracy: 0.000001)
        XCTAssertGreaterThan(try XCTUnwrap(roi.percentage), 1.8)
    }

    func test_tipsWithNoFavouriteComparisonFallOutOfBothSubsets() {
        let report = AccuracyCalculator.report(for: [tip("a", outcome: .won(betfairSP: 4.0), agreed: nil)])

        XCTAssertEqual(report.whenAgreeingWithFavourite.settled, 0)
        XCTAssertEqual(report.whenDisagreeing.settled, 0)
        XCTAssertEqual(report.settled, 1, "it still counts overall")
    }
}
