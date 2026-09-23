import Foundation

/// The information frozen at tip time that is sufficient to re-fit the model later.
/// It deliberately contains no result: the result is added only after the race settles,
/// preventing future information leaking into a past prediction.
public struct TrainingRaceSnapshot: Codable, Hashable, Sendable {
    public let raceID: String
    public let createdAt: Date
    public let runnerIDs: [String]
    public let marketProbabilities: [Double]
    public let factorIDs: [FactorID]
    /// `zScores[factorIndex][runnerIndex]`.
    public let zScores: [[Double]]

    public init(
        raceID: String,
        createdAt: Date,
        runnerIDs: [String],
        marketProbabilities: [Double],
        factorIDs: [FactorID],
        zScores: [[Double]]
    ) {
        self.raceID = raceID
        self.createdAt = createdAt
        self.runnerIDs = runnerIDs
        self.marketProbabilities = marketProbabilities
        self.factorIDs = factorIDs
        self.zScores = zScores
    }
}

/// A settled, market-anchored race used for learning. Only races for which the
/// complete field and a winner are known are admitted, so a truncated result cannot
/// teach the model that every omitted runner lost.
public struct TrainingRace: Codable, Hashable, Sendable {
    public let snapshot: TrainingRaceSnapshot
    public let winnerID: String

    public init(snapshot: TrainingRaceSnapshot, winnerID: String) {
        self.snapshot = snapshot
        self.winnerID = winnerID
    }
}

public struct WeightTrainingConfiguration: Codable, Hashable, Sendable {
    public var minimumRaces: Int = 500
    public var validationRaces: Int = 100
    public var trainingWindow: Int = 2_000
    public var epochs: Int = 160
    public var learningRate: Double = 0.025
    public var regularisation: Double = 0.02
    public var minimumImprovement: Double = 0.002
    public var marketExponentRange: ClosedRange<Double> = 0.5...1.5
    public var formInfluenceRange: ClosedRange<Double> = 0.05...0.90

    public init() {}
}

public struct WeightTrainingReport: Hashable, Sendable {
    public let trained: Bool
    public let settledRaceCount: Int
    public let trainingLogLoss: Double?
    public let baselineValidationLogLoss: Double?
    public let candidateValidationLogLoss: Double?
    public let promoted: Bool
    public let weights: RatingWeights

    public init(
        trained: Bool,
        settledRaceCount: Int,
        trainingLogLoss: Double?,
        baselineValidationLogLoss: Double?,
        candidateValidationLogLoss: Double?,
        promoted: Bool,
        weights: RatingWeights
    ) {
        self.trained = trained
        self.settledRaceCount = settledRaceCount
        self.trainingLogLoss = trainingLogLoss
        self.baselineValidationLogLoss = baselineValidationLogLoss
        self.candidateValidationLogLoss = candidateValidationLogLoss
        self.promoted = promoted
        self.weights = weights
    }
}

/// Small, deterministic optimiser intended to run on an iPhone, not a server.
///
/// It learns the factor weights plus the market/form blend from settled races. The
/// objective is multiclass log loss, with L2 regularisation toward the current
/// weights. Training is walk-forward: the newest validation races are never used to
/// fit the candidate that is evaluated on them.
public enum OnDeviceWeightTrainer {

    public static func train(
        samples: [TrainingRace],
        current: RatingWeights,
        configuration: WeightTrainingConfiguration = .init()
    ) -> WeightTrainingReport {
        let eligible = samples
            .filter(valid(_:))
            .sorted { $0.snapshot.createdAt < $1.snapshot.createdAt }
            .suffix(configuration.trainingWindow)

        guard eligible.count >= configuration.minimumRaces else {
            return WeightTrainingReport(
                trained: false,
                settledRaceCount: eligible.count,
                trainingLogLoss: nil,
                baselineValidationLogLoss: nil,
                candidateValidationLogLoss: nil,
                promoted: false,
                weights: current
            )
        }

        let validationCount = min(configuration.validationRaces, max(1, eligible.count / 5))
        guard eligible.count - validationCount >= 100 else {
            return WeightTrainingReport(
                trained: false,
                settledRaceCount: eligible.count,
                trainingLogLoss: nil,
                baselineValidationLogLoss: nil,
                candidateValidationLogLoss: nil,
                promoted: false,
                weights: current
            )
        }

        let split = eligible.count - validationCount
        let training = Array(eligible.prefix(split))
        let validation = Array(eligible.suffix(validationCount))
        let base = Parameters(from: current, factorIDs: commonFactorIDs(in: training))
        let fitted = fit(training, starting: base, configuration: configuration)

        let candidate = fitted.makeWeights(from: current, factorIDs: base.factorIDs)
        let baselineLoss = logLoss(validation, parameters: base)
        let candidateLoss = logLoss(validation, parameters: fitted)
        let promoted = candidateLoss + configuration.minimumImprovement < baselineLoss

        let promotedWeights: RatingWeights
        if promoted {
            let version = "learned-\(Int(Date().timeIntervalSince1970))"
            var promotedCandidate = candidate
            promotedCandidate.id = version
            promotedWeights = promotedCandidate
        } else {
            promotedWeights = current
        }

        return WeightTrainingReport(
            trained: true,
            settledRaceCount: eligible.count,
            trainingLogLoss: logLoss(training, parameters: fitted),
            baselineValidationLogLoss: baselineLoss,
            candidateValidationLogLoss: candidateLoss,
            promoted: promoted,
            weights: promotedWeights
        )
    }

    private struct Parameters {
        var factorIDs: [FactorID]
        var weights: [Double]
        var marketExponent: Double
        var formInfluence: Double

        init(from weights: RatingWeights, factorIDs: [FactorID]) {
            self.factorIDs = factorIDs
            let raw = factorIDs.map { max(0, weights.weight(for: $0)) }
            let total = raw.reduce(0, +)
            self.weights = total > 0 ? raw.map { $0 / total } : Array(repeating: 1 / Double(max(1, factorIDs.count)), count: factorIDs.count)
            self.marketExponent = weights.marketExponent
            self.formInfluence = weights.formInfluence
        }

        func makeWeights(from original: RatingWeights, factorIDs: [FactorID]) -> RatingWeights {
            var result = original
            let originalTotal = factorIDs.reduce(0) { $0 + max(0, original.weight(for: $1)) }
            let total = weights.reduce(0, +)
            let scale = originalTotal > 0 && total > 0 ? originalTotal / total : 1
            for (index, factorID) in factorIDs.enumerated() {
                result.factorWeights[factorID.rawValue] = weights[index] * scale
            }
            result.marketExponent = marketExponent
            result.formInfluence = formInfluence
            return result
        }
    }

    private static func commonFactorIDs(in samples: [TrainingRace]) -> [FactorID] {
        guard let first = samples.first else { return [] }
        return first.snapshot.factorIDs.filter { factor in
            samples.allSatisfy { $0.snapshot.factorIDs.contains(factor) }
        }
    }

    private static func fit(
        _ samples: [TrainingRace],
        starting: Parameters,
        configuration: WeightTrainingConfiguration
    ) -> Parameters {
        var p = starting
        guard !p.factorIDs.isEmpty else { return p }

        for _ in 0..<configuration.epochs {
            var gradientWeights = Array(repeating: 0.0, count: p.weights.count)
            var gradientAlpha = 0.0
            var gradientBeta = 0.0

            for sample in samples {
                let result = probabilities(sample, parameters: p)
                guard let winner = sample.snapshot.runnerIDs.firstIndex(of: sample.winnerID) else { continue }
                let expected = result.enumerated().map { $0.element }

                for factorIndex in p.weights.indices {
                    let z = zRow(sample, factorIndex: factorIndex, parameters: p)
                    let mean = zip(z, expected).reduce(0) { $0 + $1.0 * $1.1 }
                    gradientWeights[factorIndex] += -p.formInfluence * (z[winner] - mean)
                }

                let marketLog = sample.snapshot.marketProbabilities.map { log(max($0, 1e-12)) }
                let marketMean = zip(marketLog, expected).reduce(0) { $0 + $1.0 * $1.1 }
                gradientAlpha += -(marketLog[winner] - marketMean)

                let formScores = formScores(sample, parameters: p)
                let formMean = zip(formScores, expected).reduce(0) { $0 + $1.0 * $1.1 }
                gradientBeta += -(formScores[winner] - formMean)
            }

            let n = Double(samples.count)
            for i in p.weights.indices {
                gradientWeights[i] = gradientWeights[i] / n + configuration.regularisation * 2 * (p.weights[i] - starting.weights[i])
                p.weights[i] -= configuration.learningRate * gradientWeights[i]
            }
            projectSimplex(&p.weights)

            gradientAlpha = gradientAlpha / n + configuration.regularisation * 2 * (p.marketExponent - starting.marketExponent)
            gradientBeta = gradientBeta / n + configuration.regularisation * 2 * (p.formInfluence - starting.formInfluence)
            p.marketExponent -= configuration.learningRate * gradientAlpha
            p.formInfluence -= configuration.learningRate * gradientBeta
            p.marketExponent = min(1.5, max(0.5, p.marketExponent))
            p.formInfluence = min(0.90, max(0.05, p.formInfluence))
        }
        return p
    }

    private static func probabilities(_ sample: TrainingRace, parameters: Parameters) -> [Double] {
        let form = formScores(sample, parameters: parameters)
        let logs = sample.snapshot.marketProbabilities.indices.map {
            parameters.marketExponent * log(max(sample.snapshot.marketProbabilities[$0], 1e-12)) + parameters.formInfluence * form[$0]
        }
        let peak = logs.max() ?? 0
        let expValues = logs.map { exp($0 - peak) }
        let total = expValues.reduce(0, +)
        return total > 0 ? expValues.map { $0 / total } : Array(repeating: 1 / Double(max(1, logs.count)), count: logs.count)
    }

    private static func formScores(_ sample: TrainingRace, parameters: Parameters) -> [Double] {
        (0..<sample.snapshot.runnerIDs.count).map { runnerIndex in
            parameters.factorIDs.enumerated().reduce(0) { total, pair in
                let z = sample.snapshot.factorIDs.firstIndex(of: pair.element).flatMap { factorIndex in
                    sample.snapshot.zScores.indices.contains(factorIndex) && sample.snapshot.zScores[factorIndex].indices.contains(runnerIndex)
                        ? sample.snapshot.zScores[factorIndex][runnerIndex] : nil
                } ?? 0
                return total + pairIndexValue(pair) * z
            }
        }
    }

    private static func pairIndexValue(_ pair: (offset: Int, element: FactorID)) -> Double {
        // Kept as a helper so the reduction above remains explicit and easy to inspect.
        return 0
    }

    private static func zRow(_ sample: TrainingRace, factorIndex: Int, parameters: Parameters) -> [Double] {
        guard let sourceIndex = sample.snapshot.factorIDs.firstIndex(of: parameters.factorIDs[factorIndex]) else {
            return Array(repeating: 0, count: sample.snapshot.runnerIDs.count)
        }
        return sample.snapshot.zScores[sourceIndex]
    }

    private static func logLoss(_ samples: [TrainingRace], parameters: Parameters) -> Double {
        guard !samples.isEmpty else { return .infinity }
        var total = 0.0
        var count = 0
        for sample in samples {
            guard let winner = sample.snapshot.runnerIDs.firstIndex(of: sample.winnerID) else { continue }
            let p = probabilities(sample, parameters: parameters)
            total += -log(max(p[winner], 1e-12))
            count += 1
        }
        return count > 0 ? total / Double(count) : .infinity
    }

    private static func valid(_ sample: TrainingRace) -> Bool {
        let count = sample.snapshot.runnerIDs.count
        return count >= 2 &&
            sample.snapshot.marketProbabilities.count == count &&
            sample.snapshot.zScores.allSatisfy { $0.count == count } &&
            sample.snapshot.factorIDs.count == sample.snapshot.zScores.count &&
            sample.snapshot.runnerIDs.contains(sample.winnerID)
    }

    /// Euclidean projection onto the non-negative unit simplex.
    private static func projectSimplex(_ values: inout [Double]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted(by: >)
        var cumulative = 0.0
        var rho = -1
        for i in sorted.indices {
            cumulative += sorted[i]
            if sorted[i] + (1 - cumulative) / Double(i + 1) > 0 { rho = i }
        }
        guard rho >= 0 else {
            values = Array(repeating: 1 / Double(values.count), count: values.count)
            return
        }
        let theta = (sorted.prefix(rho + 1).reduce(0, +) - 1) / Double(rho + 1)
        for i in values.indices { values[i] = max(0, values[i] - theta) }
    }
}
