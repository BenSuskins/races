import XCTest
@testable import Races
import RacesKit

/// `@MainActor async` throughout — see the gotcha in CLAUDE.md.
///
/// These tests are mostly about honesty rather than arithmetic. The screen's one
/// job is telling the truth about the model, and the ways it could quietly lie —
/// hiding the zero-weight factors, or calling a factor live when its archive is
/// empty — are what is asserted here.
final class AlgorithmViewModelTests: XCTestCase {

    @MainActor
    private func makeModel(
        weights: RatingWeights = .v1,
        server: FakeRacesServer? = nil
    ) -> AlgorithmViewModel {
        AlgorithmViewModel(link: ServerLink(server: server), weights: weights)
    }

    @MainActor
    func test_everyFactorIsListedIncludingTheZeroWeightedOnes() async {
        let model = makeModel()

        // All twelve. Listing only the live ones would imply the model considers
        // nothing else, when "code present, weight zero, reason given" is both
        // more useful and more honest.
        XCTAssertEqual(model.factors.count, FactorID.allCases.count)
        XCTAssertEqual(model.totalFactorCount, FactorID.allCases.count)
    }

    @MainActor
    func test_factorsAreOrderedHeaviestFirst() async {
        let model = makeModel()

        let weights = model.factors.map(\.weight)
        XCTAssertEqual(weights, weights.sorted(by: >))
        XCTAssertEqual(model.factors.first?.id, .officialRating)
    }

    @MainActor
    func test_theBarIsRelativeToTheHeaviestFactor() async throws {
        let model = makeModel()

        // Relative to the largest weight rather than the share of the total: a
        // bar you can compare at a glance beats one that is arithmetically
        // purer and visually flat.
        let heaviest = try XCTUnwrap(model.factors.first)
        XCTAssertEqual(heaviest.relative, 1.0)

        let recentForm = try XCTUnwrap(model.factors.first { $0.id == .recentForm })
        XCTAssertEqual(
            recentForm.relative, recentForm.weight / heaviest.weight, accuracy: 0.0001)
    }

    @MainActor
    func test_aZeroWeightedFactorIsInactiveAndSaysWhyItExists() async throws {
        let model = makeModel()

        let draw = try XCTUnwrap(model.factors.first { $0.id == .draw })
        XCTAssertEqual(draw.weight, 0)
        XCTAssertFalse(draw.isActive)
        XCTAssertNotNil(draw.inactiveReason)
        // The rationale is what makes the zero legible rather than looking like
        // a bug someone forgot to fix.
        XCTAssertNotNil(draw.rationale)
    }

    @MainActor
    func test_aWeightedFactorWithNoArchiveIsReportedAsWaitingNotAsLive() async throws {
        // The trap this guards: a non-zero weight beside "Jockey strike rate"
        // reads as in play, and on a fresh install it is not — the archive is
        // empty, so the factor reports no value for every runner.
        var weights = RatingWeights.v1
        // A new id alongside the changed weight, as the model's own rule
        // requires: tuning under the same id silently invalidates the history.
        weights.id = "test-jockey"
        weights.factorWeights[FactorID.jockeyStrikeRate.rawValue] = 0.10
        let model = makeModel(weights: weights)

        let jockey = try XCTUnwrap(model.factors.first { $0.id == .jockeyStrikeRate })
        XCTAssertEqual(jockey.weight, 0.10)
        XCTAssertFalse(jockey.isActive)
        XCTAssertEqual(jockey.inactiveReason?.contains("archive"), true)
    }

    @MainActor
    func test_theSameFactorGoesLiveOnceTheArchiveHasSomething() async throws {
        var weights = RatingWeights.v1
        weights.id = "test-trainer"
        weights.factorWeights[FactorID.trainerStrikeRate.rawValue] = 0.10
        let server = FakeRacesServer(model: .success(ServerModel(active: weights, archivedRaces: 1)))

        let model = makeModel(server: server)
        await model.loadIfNeeded()

        let trainer = try XCTUnwrap(model.factors.first { $0.id == .trainerStrikeRate })
        XCTAssertTrue(trainer.isActive)
        XCTAssertNil(trainer.inactiveReason)
        XCTAssertEqual(model.archivedRaceCount, 1)
        XCTAssertEqual(model.weightsID, "test-trainer", "the screen shows the weights the server runs")
    }

    @MainActor
    func test_theLiveCountMatchesTheFactorsActuallyContributing() async {
        let model = makeModel()

        XCTAssertEqual(model.liveFactorCount, model.factors.filter(\.isActive).count)
        // Four ship at zero on v1 — draw, headgear and the two strike rates.
        XCTAssertEqual(model.liveFactorCount, 8)
    }

    @MainActor
    func test_theShippedConfigurationIsNotMarketOnly() async {
        let model = makeModel()

        // If this ever flips, the screen must say so rather than implying the
        // model is adding something. β = 0 means the output *is* the market.
        XCTAssertFalse(model.isMarketOnly)
        XCTAssertEqual(model.formInfluence, 0.35)
    }

    @MainActor
    func test_theControlConfigurationIsReportedAsMarketOnly() async {
        let model = makeModel(weights: .marketOnly)

        XCTAssertTrue(model.isMarketOnly)
        XCTAssertEqual(model.liveFactorCount, 0)
    }

    @MainActor
    func test_theVersionStampsMatchWhatGoesIntoATip() async {
        let assessment = RaceRater(weights: .v2).rate(
            .fixture(runners: [.fixture(id: "a"), .fixture(id: "b")]))
        let server = FakeRacesServer(model: .success(ServerModel(active: .v2, samples: ["settled": 12, "minimumRaces": 500])))
        let model = makeModel(server: server)
        await model.loadIfNeeded()

        // The screen must report the same identifiers the ledger records, or it
        // is describing a model other than the one that produced the tips.
        XCTAssertEqual(model.modelVersion, assessment.modelVersion)
        XCTAssertEqual(model.weightsID, assessment.weightsID)
        XCTAssertEqual(model.trainingSamples, 12)
        XCTAssertEqual(model.trainingMinimum, 500)
    }

    @MainActor
    func test_formPointsAreListedInFinishingOrderNotDictionaryOrder() async throws {
        let model = makeModel()

        let labels = model.formPoints.map(\.label)
        XCTAssertEqual(Array(labels.prefix(3)), ["1st", "2nd", "3rd"])
        XCTAssertEqual(labels.last, "Didn't complete")
        // Monotonically decreasing, which is the property a reader checks at a
        // glance and a shuffled dictionary would break.
        let points = model.formPoints.map(\.points)
        XCTAssertEqual(points, points.sorted(by: >))
    }

    @MainActor
    func test_withNoServerTheScreenStillDescribesTheModel() async {
        // The screen must work before anything is configured: it shows the
        // kit's weights and says the server could not be reached.
        let model = makeModel(server: nil)
        await model.loadIfNeeded()

        XCTAssertEqual(model.archivedRaceCount, 0)
        XCTAssertNotNil(model.loadFailure)
        XCTAssertEqual(model.factors.count, FactorID.allCases.count)
        XCTAssertFalse(model.weightsID.isEmpty)
    }
}
