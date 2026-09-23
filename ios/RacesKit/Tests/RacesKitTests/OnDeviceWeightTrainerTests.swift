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

    func test_learnsFactorThatConsistentlyExplainsTheWinner() {
        let samples = makeSamples(count: 40)
        var configuration = WeightTrainingConfiguration()
        configuration.minimumRaces = 20
        configuration.validationRaces = 5
        configuration.trainingWindow = 40
        configuration.epochs = 80

        let report = OnDeviceWeightTrainer.train(
            samples: samples,
            current: .v1,
            configuration: configuration
        )

        XCTAssertTrue(report.trained)
        XCTAssertNotNil(report.baselineValidationLogLoss)
        XCTAssertNotNil(report.candidateValidationLogLoss)
        XCTAssertTrue(report.candidateValidationLogLoss! < report.baselineValidationLogLoss!)
        XCTAssertTrue(report.promoted)
        XCTAssertEqual(report.weights.factorWeights[FactorID.officialRating.rawValue], 1.05, accuracy: 0.05)
        XCTAssertEqual(report.weights.marketExponent, 1.0, accuracy: 0.15)
        XCTAssertGreaterThan(report.weights.formInfluence, RatingWeights.v1.formInfluence)
    }

    func test_retrainingKeepsMarketAndFormWithinConfiguredBounds() {
        let samples = makeSamples(count: 40)
        var configuration = WeightTrainingConfiguration()
        configuration.minimumRaces = 20
        configuration.validationRaces = 5
        configuration.trainingWindow = 40
        configuration.epochs = 80
        configuration.marketExponentRange = 0.8...1.2
        configuration.formInfluenceRange = 0.20...0.50

        let report = OnDeviceWeightTrainer.train(
            samples: samples,
            current: .v1,
            configuration: configuration
        )

        XCTAssertGreaterThanOrEqual(report.weights.marketExponent, 0.8)
        XCTAssertLessThanOrEqual(report.weights.marketExponent, 1.2)
        XCTAssertGreaterThanOrEqual(report.weights.formInfluence, 0.20)
        XCTAssertLessThanOrEqual(report.weights.formInfluence, 0.50)
    }

    private func makeSamples(count: Int) -> [TrainingRace] {
        (0..<count).map { index in
            let winner = ["a", "b", "c"][index % 3]
            let zScores = [
                [2.0, -1.0, -1.0],
                [0.0, 0.0, 0.0],
            ]
            let snapshot = TrainingRaceSnapshot(
                raceID: "race-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                runnerIDs: ["a", "b", "c"],
                marketProbabilities: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
                factorIDs: [.officialRating, .recentForm],
                zScores: index % 3 == 0
                    ? zScores
                    : index % 3 == 1
                        ? [[-1.0, 2.0, -1.0], [0.0, 0.0, 0.0]]
                        : [[-1.0, -1.0, 2.0], [0.0, 0.0, 0.0]]
            )
            return TrainingRace(snapshot: snapshot, winnerID: winner)
        }
    }
}
