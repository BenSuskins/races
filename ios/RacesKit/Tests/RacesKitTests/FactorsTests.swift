import XCTest
@testable import RacesKit

final class FactorsTests: XCTestCase {

    private func context(
        name: String = "Test Stakes",
        type: RaceType = .flat,
        ratingBand: ClosedRange<Int>? = nil,
        ageBand: String? = "3yo+",
        strikeRates: (any StrikeRateProviding)? = nil
    ) -> FactorContext {
        FactorContext(
            race: TestRace.race(name: name, type: type, ratingBand: ratingBand, ageBand: ageBand, runners: []),
            strikeRates: strikeRates
        )
    }

    // MARK: - Official rating

    func test_officialRating() {
        let factor = OfficialRatingFactor()

        let rated = factor.value(for: TestRace.runner("a", officialRating: 82), in: context())
        XCTAssertEqual(rated.raw, 82)
        XCTAssertEqual(rated.display, "OR 82")
        XCTAssertTrue(rated.availability.isAvailable)

        let unrated = factor.value(for: TestRace.runner("b", officialRating: nil), in: context())
        XCTAssertNil(unrated.raw)
        XCTAssertEqual(unrated.availability, .missingData("no official rating"))
    }

    // MARK: - Handicap band

    func test_handicapBandPosition() throws {
        let factor = HandicapBandPositionFactor()
        let handicap = context(name: "Ascot Handicap", ratingBand: 0...95)

        let top = factor.value(for: TestRace.runner("a", officialRating: 95), in: handicap)
        XCTAssertEqual(try XCTUnwrap(top.raw), 1.0, accuracy: 0.0001)

        let bottom = factor.value(for: TestRace.runner("b", officialRating: 0), in: handicap)
        XCTAssertEqual(try XCTUnwrap(bottom.raw), 0.0, accuracy: 0.0001)
    }

    /// Outside a handicap the official rating is not a common scale, so the factor
    /// stands aside rather than pretending otherwise.
    func test_handicapBandStandsAsideOutsideAHandicap() {
        let factor = HandicapBandPositionFactor()
        let value = factor.value(for: TestRace.runner("a", officialRating: 95), in: context(ratingBand: 0...95))

        XCTAssertEqual(value.availability, .notApplicable("not a handicap"))
    }

    func test_handicapBandNeedsAPublishedBand() {
        let factor = HandicapBandPositionFactor()
        let value = factor.value(
            for: TestRace.runner("a", officialRating: 95),
            in: context(name: "Ascot Handicap", ratingBand: nil)
        )
        XCTAssertEqual(value.availability, .notApplicable("no rating band published"))
    }

    // MARK: - Form-derived

    func test_recentForm() {
        let factor = RecentFormFactor()

        let raced = factor.value(for: TestRace.runner("a", form: "111"), in: context())
        XCTAssertEqual(raced.raw, 1.0)
        XCTAssertEqual(raced.display, "111")

        let unraced = factor.value(for: TestRace.runner("b", form: nil), in: context())
        XCTAssertEqual(unraced.availability, .missingData("no recorded form"))
        XCTAssertEqual(unraced.display, "Unraced")
    }

    func test_wonLastTime() {
        let factor = WonLastTimeFactor()

        XCTAssertEqual(factor.value(for: TestRace.runner("a", form: "231"), in: context()).raw, 1)
        XCTAssertEqual(factor.value(for: TestRace.runner("b", form: "132"), in: context()).raw, 0)
        XCTAssertNil(factor.value(for: TestRace.runner("c", form: nil), in: context()).raw)
    }

    /// Almost everything completes on the Flat, so the factor would be noise there.
    func test_completionRateAppliesOnlyOverObstacles() {
        let factor = CompletionRateFactor()

        let flat = factor.value(for: TestRace.runner("a", form: "12PU"), in: context(type: .flat))
        XCTAssertEqual(flat.availability, .notApplicable("only meaningful over obstacles"))

        let chase = factor.value(for: TestRace.runner("a", form: "12PU"), in: context(type: .chase))
        XCTAssertEqual(chase.raw, 0.5)
        XCTAssertTrue(chase.availability.isAvailable)

        let bumper = factor.value(for: TestRace.runner("a", form: "12PU"), in: context(type: .nationalHuntFlat))
        XCTAssertFalse(bumper.availability.isAvailable, "a bumper has no obstacles")
    }

    // MARK: - Days since last run

    /// Deliberately non-monotonic: both a very quick reappearance and a long
    /// layoff are mild negatives, with a broad optimum between them.
    func test_freshnessPeaksInTheMiddle() {
        let optimum = DaysSinceLastRunFactor.freshness(days: 21)

        XCTAssertEqual(optimum, 1.0)
        XCTAssertLessThan(DaysSinceLastRunFactor.freshness(days: 3), optimum)
        XCTAssertLessThan(DaysSinceLastRunFactor.freshness(days: 10), optimum)
        XCTAssertLessThan(DaysSinceLastRunFactor.freshness(days: 90), optimum)
        XCTAssertLessThan(DaysSinceLastRunFactor.freshness(days: 400), optimum)
    }

    func test_freshnessDecaysWithALongerLayoff() {
        XCTAssertGreaterThan(
            DaysSinceLastRunFactor.freshness(days: 45),
            DaysSinceLastRunFactor.freshness(days: 150)
        )
        XCTAssertGreaterThan(
            DaysSinceLastRunFactor.freshness(days: 150),
            DaysSinceLastRunFactor.freshness(days: 400)
        )
    }

    func test_freshnessHandlesNonsenseWithoutCrashing() {
        XCTAssertGreaterThan(DaysSinceLastRunFactor.freshness(days: -5), 0)
        XCTAssertGreaterThan(DaysSinceLastRunFactor.freshness(days: 0), 0)
    }

    func test_firstTimeRunnerHasNoLayoff() {
        let value = DaysSinceLastRunFactor().value(
            for: TestRace.runner("a", daysSinceLastRun: nil), in: context()
        )
        XCTAssertEqual(value.availability, .missingData("no recorded previous run"))
        XCTAssertEqual(value.display, "First run")
    }

    // MARK: - Age

    /// In a race confined to one age group everyone scores identically, so the
    /// factor contributes nothing rather than noise.
    func test_ageAppliesOnlyWhenTheRaceMixesAges() {
        let factor = AgeFactor()

        let open = factor.value(for: TestRace.runner("a", age: 5), in: context(ageBand: "3yo+"))
        XCTAssertTrue(open.availability.isAvailable)

        let confined = factor.value(for: TestRace.runner("a", age: 3), in: context(ageBand: "3yo"))
        XCTAssertEqual(confined.availability, .notApplicable("race is confined to one age group"))
    }

    func test_agePeaksLaterOverJumps() {
        let factor = AgeFactor()
        let flatSix = try? XCTUnwrap(factor.value(for: TestRace.runner("a", age: 8), in: context(type: .flat)).raw)
        let jumpsSix = try? XCTUnwrap(factor.value(for: TestRace.runner("a", age: 8), in: context(type: .chase)).raw)

        XCTAssertNotNil(flatSix)
        XCTAssertNotNil(jumpsSix)
        XCTAssertGreaterThan(jumpsSix ?? 0, flatSix ?? 0, "an 8yo is prime over fences, veteran on the Flat")
    }

    // MARK: - Weight

    /// Negated at source so that, like every other factor, higher is better.
    func test_lessWeightScoresHigher() throws {
        let factor = WeightCarriedFactor()
        let light = try XCTUnwrap(factor.value(for: TestRace.runner("a", weightPounds: 120), in: context()).raw)
        let heavy = try XCTUnwrap(factor.value(for: TestRace.runner("b", weightPounds: 140), in: context()).raw)

        XCTAssertGreaterThan(light, heavy)
    }

    // MARK: - The deliberately inert ones

    /// Draw bias is real, but it is a course × distance × going × field-size
    /// interaction and we have no bias data. Saying so is better than guessing.
    func test_drawReportsThatItHasNothingToSay() {
        let factor = DrawFactor()

        let flat = factor.value(for: TestRace.runner("a", draw: 3), in: context(type: .flat))
        XCTAssertNil(flat.raw)
        XCTAssertEqual(flat.availability, .notApplicable("no draw-bias data for this course yet"))
        XCTAssertEqual(flat.display, "Stall 3", "the draw is still shown, just not used")

        let jumps = factor.value(for: TestRace.runner("a", draw: nil), in: context(type: .chase))
        XCTAssertEqual(jumps.availability, .notApplicable("the draw doesn't apply over obstacles"))
    }

    /// The predictive angle is *first-time* headgear, and spotting that needs a
    /// headgear history the free tier does not carry.
    func test_headgearNeedsAPaidTierToBeUseful() {
        let factor = HeadgearFactor()

        let wearing = factor.value(for: TestRace.runner("a", headgear: "b"), in: context())
        XCTAssertNil(wearing.raw)
        XCTAssertEqual(wearing.availability, .requiresPaidTier("first-time headgear needs a headgear history"))
        XCTAssertEqual(wearing.display, "Wearing b")

        let bare = factor.value(for: TestRace.runner("b", headgear: nil), in: context())
        XCTAssertEqual(bare.display, "No headgear")
    }

    // MARK: - Strike rates

    func test_strikeRateNeedsAnArchive() {
        let factor = StrikeRateFactor(subject: .jockey)
        let value = factor.value(for: TestRace.runner("a", jockeyID: "jky_1"), in: context())

        XCTAssertEqual(value.availability, .missingData("no results archive yet"))
    }

    func test_strikeRateNeedsASampleWorthReading() {
        let thin = FakeStrikeRates(trainers: ["trn_1": StrikeRate(runs: 10, wins: 4)])
        let factor = StrikeRateFactor(subject: .trainer, minimumSample: 30)
        let value = factor.value(
            for: TestRace.runner("a", trainerID: "trn_1"),
            in: context(strikeRates: thin)
        )

        XCTAssertEqual(value.availability, .missingData("only 10 runs recorded so far"))
    }

    func test_strikeRateIsReportedOnceTheSampleIsBigEnough() throws {
        let solid = FakeStrikeRates(trainers: ["trn_1": StrikeRate(runs: 200, wins: 40)], baselineStrikeRate: 0.10)
        let factor = StrikeRateFactor(subject: .trainer, minimumSample: 30)
        let value = factor.value(
            for: TestRace.runner("a", trainerID: "trn_1"),
            in: context(strikeRates: solid)
        )

        XCTAssertTrue(value.availability.isAvailable)
        XCTAssertEqual(try XCTUnwrap(value.raw), 40.0 / 200.0, accuracy: 0.02)
        XCTAssertTrue(value.display.contains("200 runs"))
    }

    /// Without shrinkage the factor would be loudest exactly where the evidence is
    /// thinnest — a trainer with one win from one run is not a 100% strike rate.
    func test_shrinkagePullsSmallSamplesTowardsThePrior() {
        let tiny = StrikeRate(runs: 1, wins: 1)
        let large = StrikeRate(runs: 400, wins: 400)

        XCTAssertEqual(tiny.raw, 1.0, "the raw figure is absurd")
        XCTAssertLessThan(tiny.smoothed(towards: 0.10), 0.2, "shrunk almost all the way back")
        XCTAssertGreaterThan(large.smoothed(towards: 0.10), 0.9, "a real record survives shrinkage")
    }

    func test_strikeRateOfNoRunsIsUnknown() {
        XCTAssertNil(StrikeRate(runs: 0, wins: 0).raw)
        XCTAssertEqual(StrikeRate(runs: 0, wins: 0).smoothed(towards: 0.10), 0.10, accuracy: 0.0001)
    }
}
