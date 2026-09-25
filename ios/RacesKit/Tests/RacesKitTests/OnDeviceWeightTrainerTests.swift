import XCTest
@testable import RacesKit

final class OnDeviceWeightTrainerTests: XCTestCase {

    func test_doesNotTrainBeforeMinimumRaceCount() {
        let samples = makeSamples(count: 19)
        var configuration = WeightTrainingConfiguration()
        configuration.minimumRaces = 20
        configuration.validationRaces = 5

        let report = OnDeviceWeightTrainer.train(
            samples: samples,
            current: .v1,
            configuration: configuration
        )

        XCTAssertFalse(report.trained)
        XCTAssertFalse(report.promoted)
        XCTAssertEqual(report.settledRaceCount, 19)
        XCTAssertEqual(report.weights, .v1)
    }

    /// The trainer refuses to fit on fewer than 100 training races whatever the
    /// configuration says (`eligible.count - validationCount >= 100`). These
    /// tests used to run at 40 and assert a fit, which that floor cannot reach.
    func test_honoursTheHundredRaceFloor() {
        var configuration = WeightTrainingConfiguration()
        configuration.minimumRaces = 20
        configuration.validationRaces = 5

        let report = OnDeviceWeightTrainer.train(
            samples: makeSamples(count: 40),
            current: .v1,
            configuration: configuration
        )

        XCTAssertFalse(report.trained, "35 training races is below the floor")
        XCTAssertFalse(report.promoted)
        XCTAssertEqual(report.weights, .v1)
    }

    func test_learnsFactorThatConsistentlyExplainsTheWinner() throws {
        let report = OnDeviceWeightTrainer.train(
            samples: makeSamples(count: 150),
            current: .v1,
            configuration: fittingConfiguration()
        )

        XCTAssertTrue(report.trained)
        let baseline = try XCTUnwrap(report.baselineValidationLogLoss)
        let candidate = try XCTUnwrap(report.candidateValidationLogLoss)
        XCTAssertLessThan(candidate, baseline)
        XCTAssertTrue(report.promoted)
        XCTAssertEqual(report.weights.id, "learned-149-150", "promotion mints a new weights id")
        XCTAssertEqual(report.weights.weight(for: .officialRating), 0.55, accuracy: 0.05)
        XCTAssertEqual(report.weights.weight(for: .recentForm), 0.0, accuracy: 0.05)
        XCTAssertGreaterThan(report.weights.formInfluence, RatingWeights.v1.formInfluence)
    }

    func test_retrainingKeepsMarketAndFormWithinConfiguredBounds() {
        var configuration = fittingConfiguration()
        configuration.marketExponentRange = 0.8...1.2
        configuration.formInfluenceRange = 0.20...0.50

        let report = OnDeviceWeightTrainer.train(
            samples: makeSamples(count: 150),
            current: .v1,
            configuration: configuration
        )

        XCTAssertTrue(report.trained)
        XCTAssertGreaterThanOrEqual(report.weights.marketExponent, 0.8)
        XCTAssertLessThanOrEqual(report.weights.marketExponent, 1.2)
        XCTAssertGreaterThanOrEqual(report.weights.formInfluence, 0.20)
        XCTAssertLessThanOrEqual(report.weights.formInfluence, 0.50)
    }

    /// 150 races, 30 held back: 120 to fit on, clear of the floor. The same
    /// numbers as the server's trainer tests, which this is the original of.
    private func fittingConfiguration() -> WeightTrainingConfiguration {
        var configuration = WeightTrainingConfiguration()
        configuration.minimumRaces = 100
        configuration.validationRaces = 30
        configuration.trainingWindow = 150
        configuration.epochs = 80
        return configuration
    }

    private func makeSamples(count: Int) -> [TrainingRace] {
        (0..<count).map { index in
            let winner = ["a", "b", "c"][index % 3]
            let snapshot = TrainingRaceSnapshot(
                raceID: "race-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                runnerIDs: ["a", "b", "c"],
                marketProbabilities: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
                factorIDs: [.officialRating, .recentForm],
                zScores: index % 3 == 0
                    ? [[2.0, -1.0, -1.0], [0.0, 0.0, 0.0]]
                    : index % 3 == 1
                        ? [[-1.0, 2.0, -1.0], [0.0, 0.0, 0.0]]
                        : [[-1.0, -1.0, 2.0], [0.0, 0.0, 0.0]]
            )
            return TrainingRace(snapshot: snapshot, winnerID: winner)
        }
    }
}
