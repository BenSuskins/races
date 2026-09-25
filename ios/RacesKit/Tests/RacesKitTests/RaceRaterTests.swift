import XCTest
@testable import RacesKit

final class RaceRaterTests: XCTestCase {

    private func fourRunnerHandicap() -> Race {
        TestRace.race(
            name: "Ascot Handicap",
            ratingBand: 0...95,
            runners: [
                TestRace.runner("a", number: 1, draw: 1, officialRating: 95, form: "1-3241", daysSinceLastRun: 21),
                TestRace.runner("b", number: 2, draw: 2, officialRating: 88, form: "21-113", daysSinceLastRun: 14),
                TestRace.runner("c", number: 3, draw: 3, officialRating: 80, form: "0-450", daysSinceLastRun: 60),
                TestRace.runner("d", number: 4, draw: 4, officialRating: 72, form: "P0-08", daysSinceLastRun: 200),
            ]
        )
    }

    /// Prices chosen to carry a realistic ~5% overround. A book that happens to
    /// sum to exactly 1.00 would make the value-edge assertions knife-edge.
    private let fullMarket = TestRace.market(["a": 1.7, "b": 3.4, "c": 8.5, "d": 19.0])

    private func assessedRunner(
        _ id: String,
        probability: Double,
        odds: Double
    ) -> RunnerAssessment {
        RunnerAssessment(
            horseID: id,
            horseName: id,
            clothNumber: nil,
            marketProbability: 1 / odds,
            marketBackPrice: odds,
            formScore: 0,
            winProbability: probability,
            contributions: []
        )
    }

    private func syntheticMarketAssessment(
        runners: [RunnerAssessment],
        minimumValueEdge: Double = 0.05,
        minimumValueProbability: Double = 0.08
    ) -> RaceAssessment {
        RaceAssessment(
            raceID: "synthetic",
            generatedAt: Date(timeIntervalSince1970: 0),
            modelVersion: RaceRater.modelVersion,
            weightsID: "v2",
            marketSource: .liveExchange,
            marketCoverage: 1,
            isMarketDelayed: false,
            runners: runners,
            confidence: .medium,
            minimumValueEdge: minimumValueEdge,
            minimumValueProbability: minimumValueProbability
        )
    }

    // MARK: - The property the whole design rests on

    /// **At β = 0 the model reproduces the market exactly.**
    ///
    /// This is what makes "is any of this doing anything?" a measurement rather
    /// than an opinion: the back-test compares the model against β = 0, and any
    /// weighting that loses to it is doing active harm. If this test ever fails,
    /// the blend maths is wrong and every number the app reports is untrustworthy.
    func test_zeroFormInfluenceReproducesTheMarketExactly() throws {
        let rater = RaceRater(weights: .marketOnly)
        let assessment = rater.rate(fourRunnerHandicap(), market: fullMarket)

        XCTAssertEqual(assessment.runners.count, 4)
        for runner in assessment.runners {
            let market = try XCTUnwrap(runner.marketProbability, runner.horseName)
            XCTAssertEqual(
                runner.winProbability, market, accuracy: 0.000001,
                "\(runner.horseName) should be exactly the market's own view"
            )
        }
    }

    func test_probabilitiesAlwaysSumToOne() {
        let cases: [(String, MarketSnapshot?)] = [
            ("with a market", fullMarket),
            ("without a market", nil),
        ]
        for (label, market) in cases {
            let assessment = RaceRater().rate(fourRunnerHandicap(), market: market)
            let total = assessment.runners.map(\.winProbability).reduce(0, +)
            XCTAssertEqual(total, 1.0, accuracy: 0.000001, label)
        }
    }

    func test_everyProbabilityIsAValidProbability() {
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: fullMarket)
        for runner in assessment.runners {
            XCTAssertTrue(runner.winProbability.isFinite, runner.horseName)
            XCTAssertGreaterThan(runner.winProbability, 0)
            XCTAssertLessThan(runner.winProbability, 1)
        }
    }

    func test_runnersAreReturnedInRankOrder() {
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: fullMarket)
        let probabilities = assessment.runners.map(\.winProbability)

        XCTAssertEqual(probabilities, probabilities.sorted(by: >))
        XCTAssertEqual(assessment.selection?.horseID, assessment.runners.first?.horseID)
    }

    /// The model is allowed to disagree with the market, but not wildly: β bounds
    /// how far it can move. A well-fancied favourite should stay well fancied.
    func test_theModelStaysAnchoredToTheMarket() throws {
        let assessment = RaceRater(weights: .v1).rate(fourRunnerHandicap(), market: fullMarket)
        let favourite = try XCTUnwrap(assessment.runners.first { $0.horseID == "a" })
        let market = try XCTUnwrap(favourite.marketProbability)

        XCTAssertEqual(favourite.winProbability, market, accuracy: 0.25)
    }

    // MARK: - Value-aware selection

    func test_selectionPrefersMeaningfulPositiveValueOverTheFavourite() {
        let assessment = syntheticMarketAssessment(runners: [
            assessedRunner("favourite", probability: 0.40, odds: 2.20),
            assessedRunner("value", probability: 0.30, odds: 4.50),
            assessedRunner("longshot", probability: 0.09, odds: 15.0),
        ])

        XCTAssertEqual(assessment.selection?.horseID, "value")
        XCTAssertGreaterThan(assessment.selection?.valueEdge ?? 0, 0.05)
        XCTAssertNotEqual(assessment.selection?.horseID, assessment.marketFavourite?.horseID)
    }

    func test_selectionDoesNotChaseTinyProbabilityLongshots() {
        let assessment = syntheticMarketAssessment(runners: [
            assessedRunner("favourite", probability: 0.45, odds: 2.20),
            assessedRunner("solid", probability: 0.15, odds: 7.0),
            assessedRunner("longshot", probability: 0.04, odds: 30.0),
        ])

        XCTAssertEqual(assessment.selection?.horseID, "solid")
    }

    func test_selectionFallsBackToHighestProbabilityWhenNoRunnerClearsValueThreshold() {
        let assessment = syntheticMarketAssessment(runners: [
            assessedRunner("favourite", probability: 0.40, odds: 2.20),
            assessedRunner("second", probability: 0.30, odds: 3.20),
            assessedRunner("third", probability: 0.20, odds: 5.0),
        ])

        XCTAssertTrue(assessment.runners.allSatisfy { ($0.valueEdge ?? 0) < 0.05 })
        XCTAssertEqual(assessment.selection?.horseID, "favourite")
    }

    func test_formOnlySelectionRemainsHighestProbabilityRunner() {
        let runners = [
            assessedRunner("a", probability: 0.45, odds: 2.0),
            assessedRunner("b", probability: 0.35, odds: 4.0),
        ]
        let assessment = RaceAssessment(
            raceID: "synthetic",
            generatedAt: Date(timeIntervalSince1970: 0),
            modelVersion: RaceRater.modelVersion,
            weightsID: "v2",
            marketSource: nil,
            marketCoverage: 0,
            isMarketDelayed: false,
            runners: runners,
            confidence: .medium
        )

        XCTAssertEqual(assessment.selection?.horseID, "a")
    }

    /// A 15% pick above a 35% runner is the value layer working, not a bug, and
    /// the app can only say so if the assessment can tell the two apart.
    func test_aValuePickIsDistinguishedFromTheTopRatedRunner() {
        let assessment = syntheticMarketAssessment(runners: [
            assessedRunner("likely", probability: 0.35, odds: 2.5),
            assessedRunner("value", probability: 0.15, odds: 9.0),
        ])

        XCTAssertEqual(assessment.selection?.horseID, "value")
        XCTAssertEqual(assessment.topRated?.horseID, "likely")
        XCTAssertTrue(assessment.isValuePick)
    }

    /// v3 switches the value layer off: the same field that gives v2 a value
    /// pick gives v3 its most likely winner.
    func test_v3AlwaysPicksTheMostLikelyWinner() {
        let runners = [
            assessedRunner("likely", probability: 0.35, odds: 2.5),
            assessedRunner("value", probability: 0.15, odds: 9.0),
        ]
        let assessment = syntheticMarketAssessment(
            runners: runners,
            minimumValueEdge: RatingWeights.v3.minimumValueEdge,
            minimumValueProbability: RatingWeights.v3.minimumValueProbability)

        XCTAssertTrue(RatingWeights.v3.picksMostLikelyWinner)
        XCTAssertFalse(RatingWeights.v2.picksMostLikelyWinner)
        XCTAssertEqual(assessment.selection?.horseID, "likely")
        XCTAssertFalse(assessment.isValuePick)
    }

    func test_withNoValueTheSelectionIsTheTopRatedRunner() {
        let assessment = syntheticMarketAssessment(runners: [
            assessedRunner("likely", probability: 0.40, odds: 2.5),
            assessedRunner("other", probability: 0.10, odds: 9.0),
        ])

        XCTAssertEqual(assessment.selection?.horseID, "likely")
        XCTAssertFalse(assessment.isValuePick)
    }

    func test_probabilityEdgeIsTheModelDisagreementWithTheMarket() throws {
        let runner = assessedRunner("value", probability: 0.30, odds: 4.0)
        XCTAssertEqual(try XCTUnwrap(runner.probabilityEdge), 0.05, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(runner.valueEdge), 0.20, accuracy: 0.000001)
    }

    // MARK: - No market

    func test_withoutAMarketItFallsBackToFormAndSaysSo() {
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: nil)

        XCTAssertTrue(assessment.isFormOnly)
        XCTAssertNil(assessment.marketSource)
        XCTAssertEqual(assessment.marketCoverage, 0)
        XCTAssertTrue(assessment.runners.allSatisfy { $0.marketProbability == nil })
        XCTAssertNil(assessment.agreesWithMarket)
    }

    func test_formOnlyRatingStillPicksTheBestOnTheNumbers() throws {
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: nil)
        let selection = try XCTUnwrap(assessment.selection)

        XCTAssertEqual(selection.horseID, "a", "top-rated with the best recent form")
        XCTAssertGreaterThan(selection.winProbability, 1.0 / 4.0, "better than a uniform guess")
    }

    /// A book missing several runners is not a book, and de-vigging what remains
    /// would quietly inflate everyone else. Below the threshold it is discarded
    /// wholesale rather than used to anchor part of the race.
    func test_aThinlyPricedMarketIsDiscardedWholesale() {
        let sparse = TestRace.market(["a": 1.8, "b": 3.5])
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: sparse)

        XCTAssertTrue(assessment.isFormOnly)
        XCTAssertEqual(assessment.marketCoverage, 0.5, accuracy: 0.0001)
        XCTAssertTrue(assessment.runners.allSatisfy { $0.marketProbability == nil })
    }

    func test_aMarketAtTheCoverageThresholdIsUsed() {
        let race = TestRace.race(runners: (1...5).map {
            TestRace.runner("h\($0)", number: $0, officialRating: 80 + $0, form: "111")
        })
        // Four of five priced: exactly the 0.8 threshold.
        let market = TestRace.market(["h1": 2.0, "h2": 4.0, "h3": 6.0, "h4": 8.0])
        let assessment = RaceRater().rate(race, market: market)

        XCTAssertFalse(assessment.isFormOnly)
        XCTAssertEqual(assessment.marketCoverage, 0.8, accuracy: 0.0001)
        XCTAssertEqual(assessment.runners.map(\.winProbability).reduce(0, +), 1.0, accuracy: 0.000001)
    }

    // MARK: - Explanations

    func test_everyRunnerCarriesAContributionForEveryFactor() throws {
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: fullMarket)
        let runner = try XCTUnwrap(assessment.runners.first)

        XCTAssertEqual(runner.contributions.count, FactorID.allCases.count)
        XCTAssertEqual(Set(runner.contributions.map(\.factor)), Set(FactorID.allCases))
    }

    func test_unavailableFactorsExplainThemselvesAndStayNeutral() throws {
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: fullMarket)
        let runner = try XCTUnwrap(assessment.runners.first)

        let draw = try XCTUnwrap(runner.contributions.first { $0.factor == .draw })
        XCTAssertFalse(draw.availability.isAvailable)
        XCTAssertNotNil(draw.availability.reason)
        XCTAssertNil(draw.zScore)
        XCTAssertEqual(draw.direction, .neutral)

        let headgear = try XCTUnwrap(runner.contributions.first { $0.factor == .headgear })
        XCTAssertEqual(headgear.availability, .requiresPaidTier("first-time headgear needs a headgear history"))
    }

    /// The top-rated runner should be helped by the factor it is strongest on.
    func test_leaveOneOutDeltasPointTheRightWay() throws {
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: fullMarket)

        let best = try XCTUnwrap(assessment.runners.first { $0.horseID == "a" })
        let worst = try XCTUnwrap(assessment.runners.first { $0.horseID == "d" })

        let bestRating = try XCTUnwrap(best.contributions.first { $0.factor == .officialRating })
        let worstRating = try XCTUnwrap(worst.contributions.first { $0.factor == .officialRating })

        XCTAssertGreaterThan(bestRating.probabilityDelta, 0, "top-rated should gain from the rating")
        XCTAssertLessThan(worstRating.probabilityDelta, 0, "bottom-rated should lose by it")
        XCTAssertEqual(bestRating.direction, .positive)
        XCTAssertEqual(worstRating.direction, .negative)
    }

    /// A zero-weight factor does nothing, and its delta should say so rather than
    /// reporting a spurious effect.
    func test_zeroWeightFactorsHaveNoEffect() throws {
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: fullMarket)
        let runner = try XCTUnwrap(assessment.runners.first)

        for id in [FactorID.draw, .headgear, .jockeyStrikeRate, .trainerStrikeRate, .jockeySurfaceStrikeRate, .trainerSurfaceStrikeRate] {
            let contribution = try XCTUnwrap(runner.contributions.first { $0.factor == id })
            XCTAssertEqual(contribution.weight, 0, "\(id)")
            XCTAssertEqual(contribution.probabilityDelta, 0, accuracy: 0.000001, "\(id)")
        }
    }

    // MARK: - Provenance

    func test_theAssessmentStampsItsOwnIdentity() {
        let assessment = RaceRater(weights: .v2).rate(fourRunnerHandicap(), market: fullMarket)

        XCTAssertEqual(assessment.modelVersion, RaceRater.modelVersion)
        XCTAssertEqual(assessment.weightsID, "v2")
        XCTAssertEqual(assessment.raceID, "rac_test")
        XCTAssertEqual(assessment.minimumValueEdge, 0.05, accuracy: 0.000001)
        XCTAssertEqual(assessment.minimumValueProbability, 0.08, accuracy: 0.000001)
    }

    func test_theMarketFavouriteIsIdentifiedSeparatelyFromTheSelection() throws {
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: fullMarket)

        XCTAssertEqual(assessment.marketFavourite?.horseID, "a")
        XCTAssertNotNil(assessment.agreesWithMarket)
    }

    func test_delayedPricesAreFlagged() {
        let assessment = RaceRater().rate(fourRunnerHandicap(), market: fullMarket)
        XCTAssertTrue(assessment.isMarketDelayed, "the free Betfair key returns delayed prices")
    }

    // MARK: - Edges

    func test_anEmptyRaceIsHandledNotCrashed() {
        let assessment = RaceRater().rate(TestRace.race(runners: []))

        XCTAssertTrue(assessment.runners.isEmpty)
        XCTAssertNil(assessment.selection)
        XCTAssertEqual(assessment.confidence, .low)
    }

    func test_aSingleRunnerIsCertainAndLowConfidence() {
        let race = TestRace.race(runners: [TestRace.runner("a", officialRating: 90)])
        let assessment = RaceRater().rate(race)

        XCTAssertEqual(assessment.runners.first?.winProbability, 1.0)
        XCTAssertEqual(assessment.confidence, .low, "one runner tells us nothing")
    }

    /// A field where nothing is known about anybody should come out uniform, not
    /// arbitrarily ordered.
    func test_aFieldWeKnowNothingAboutRatesUniformly() {
        // The closure parameter is typed explicitly. Every other value here is
        // nil, so `number:` — which takes an `Int?` — was the only thing
        // constraining it, and the compiler warned that the interpolation was
        // printing an optional's debug description. Naming the type removes the
        // freedom rather than silencing the symptom, and the warning was
        // repeated once per compile unit: about thirty lines a build.
        let race = TestRace.race(runners: (1...6).map { (index: Int) in
            TestRace.runner("h\(index)", number: index, age: nil, officialRating: nil,
                            weightPounds: nil, form: nil, daysSinceLastRun: nil)
        })
        let assessment = RaceRater().rate(race)

        for runner in assessment.runners {
            XCTAssertEqual(runner.winProbability, 1.0 / 6.0, accuracy: 0.000001)
            XCTAssertEqual(runner.formScore, 0, accuracy: 0.000001)
        }
        XCTAssertEqual(assessment.confidence, .low)
    }

    func test_fairOddsAndValueEdge() throws {
        let assessment = RaceRater(weights: .marketOnly).rate(fourRunnerHandicap(), market: fullMarket)
        let favourite = try XCTUnwrap(assessment.runners.first)

        XCTAssertEqual(favourite.fairOdds, 1 / favourite.winProbability, accuracy: 0.000001)

        // At β = 0 we agree with the market exactly, so the only edge is the
        // overround itself — which means every runner shows a small negative.
        let edge = try XCTUnwrap(favourite.valueEdge)
        XCTAssertLessThan(edge, 0)
        XCTAssertGreaterThan(edge, -0.2)
    }

    func test_strikeRateFactorsStaySilentUntilTheArchiveIsWorthReading() throws {
        let race = TestRace.race(runners: [
            TestRace.runner("a", number: 1, officialRating: 90, form: "111", jockeyID: "jky_1"),
            TestRace.runner("b", number: 2, officialRating: 85, form: "222", jockeyID: "jky_2"),
        ])
        let thin = FakeStrikeRates(jockeys: ["jky_1": StrikeRate(runs: 3, wins: 3)])

        let assessment = RaceRater().rate(race, strikeRates: thin)
        let runner = try XCTUnwrap(assessment.runners.first { $0.horseID == "a" })
        let contribution = try XCTUnwrap(runner.contributions.first { $0.factor == .jockeyStrikeRate })

        XCTAssertEqual(contribution.availability, .missingData("only 3 runs recorded so far"))
        XCTAssertNil(contribution.zScore)
    }
}
