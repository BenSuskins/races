import Foundation

/// The rating engine.
///
/// ## The model
///
/// ```
/// formScoreᵢ = Σ_f  w_f · z_{f,i}              z clipped to ±clip
/// sᵢ         = p_marketᵢ ^ α  ·  exp(β · formScoreᵢ)
/// pᵢ         = sᵢ / Σⱼ sⱼ
/// ```
///
/// Probabilities stay in (0,1) and sum to 1 by construction, and each factor is a
/// clean multiplicative nudge.
///
/// But the property that actually matters is this: **at `β = 0` the output is the
/// market exactly.** The model therefore cannot be accidentally worse than its own
/// anchor without that being visible, and the only question worth asking — *is any
/// of this doing anything?* — becomes a measurement rather than an opinion. There
/// is a test asserting it, and the back-test enforces it.
///
/// ## Purity
///
/// Plain structs in, plain structs out. No network, no disk, no clock beyond an
/// injectable timestamp. That is what lets the whole thing — and the back-test —
/// run on Linux in seconds, and it is a rule worth defending.
public struct RaceRater: Sendable {

    public static let modelVersion = "market-anchored-1"

    public let weights: RatingWeights
    public let factors: [any RatingFactor]

    public init(weights: RatingWeights = .v1, factors: [any RatingFactor]? = nil) {
        self.weights = weights
        self.factors = factors ?? RaceRater.defaultFactors(for: weights)
    }

    public static func defaultFactors(for weights: RatingWeights) -> [any RatingFactor] {
        [
            OfficialRatingFactor(),
            HandicapBandPositionFactor(),
            RecentFormFactor(scorer: weights.scorer),
            WonLastTimeFactor(),
            CompletionRateFactor(),
            DaysSinceLastRunFactor(),
            AgeFactor(),
            WeightCarriedFactor(),
            DrawFactor(),
            HeadgearFactor(),
            StrikeRateFactor(subject: .jockey, minimumSample: weights.minimumStrikeRateSample),
            StrikeRateFactor(subject: .trainer, minimumSample: weights.minimumStrikeRateSample),
        ]
    }

    // MARK: - Rating

    public func rate(
        _ race: Race,
        market: MarketSnapshot? = nil,
        strikeRates: (any StrikeRateProviding)? = nil,
        now: Date = Date()
    ) -> RaceAssessment {
        let runners = race.declaredRunners
        guard !runners.isEmpty else {
            return RaceAssessment(
                raceID: race.id, generatedAt: now, modelVersion: Self.modelVersion,
                weightsID: weights.id, marketSource: nil, marketCoverage: 0,
                isMarketDelayed: false, runners: [], confidence: .low
            )
        }

        let context = FactorContext(race: race, strikeRates: strikeRates)

        // 1. Every factor's reading, standardised within this race.
        let readings = factors.map { factor -> FactorReading in
            let values = runners.map { factor.value(for: $0, in: context) }
            return FactorReading(
                id: factor.id,
                weight: weights.weight(for: factor.id),
                values: values,
                zScores: Standardiser.zScores(values.map(\.raw), clip: weights.clip)
            )
        }

        let formScores = Self.formScores(readings, count: runners.count)

        // 2. The market anchor, if there is one worth having.
        let anchor = marketAnchor(for: runners, market: market)
        let influence = anchor.isUsable ? weights.formInfluence : weights.formInfluenceNoMarket

        let probabilities = Self.combine(
            marketProbabilities: anchor.probabilities,
            formScores: formScores,
            marketExponent: weights.marketExponent,
            formInfluence: influence
        )

        // 3. What each factor was worth, measured by neutralising it.
        let deltas = leaveOneOutDeltas(
            readings: readings,
            baseline: probabilities,
            anchor: anchor,
            influence: influence,
            runnerCount: runners.count
        )

        let assessments = runners.indices.map { index -> RunnerAssessment in
            let runner = runners[index]
            return RunnerAssessment(
                horseID: runner.id,
                horseName: runner.name,
                clothNumber: runner.clothNumber,
                marketProbability: anchor.isUsable ? anchor.probabilities[index] : nil,
                marketBackPrice: market?.price(for: runner.id)?.backPrice,
                formScore: formScores[index],
                winProbability: probabilities[index],
                contributions: readings.map { reading in
                    FactorContribution(
                        factor: reading.id,
                        detail: reading.values[index].display,
                        zScore: reading.values[index].availability.isAvailable
                            ? reading.zScores[index] : nil,
                        weight: reading.weight,
                        probabilityDelta: deltas[reading.id]?[index] ?? 0,
                        availability: reading.values[index].availability
                    )
                }
            )
        }
        .sorted { $0.winProbability > $1.winProbability }

        return RaceAssessment(
            raceID: race.id,
            generatedAt: now,
            modelVersion: Self.modelVersion,
            weightsID: weights.id,
            marketSource: anchor.isUsable ? market?.source : nil,
            marketCoverage: anchor.coverage,
            isMarketDelayed: market?.isDelayed ?? false,
            runners: assessments,
            confidence: Self.confidence(of: assessments.map(\.winProbability), coverage: anchor.coverage)
        )
    }

    // MARK: - Pieces

    struct FactorReading {
        let id: FactorID
        let weight: Double
        let values: [FactorValue]
        let zScores: [Double]
    }

    struct MarketAnchor {
        let probabilities: [Double]
        let coverage: Double
        let isUsable: Bool
    }

    static func formScores(_ readings: [FactorReading], count: Int) -> [Double] {
        (0..<count).map { index in
            readings.reduce(0) { $0 + $1.weight * $1.zScores[index] }
        }
    }

    /// Build the market anchor, or a uniform prior when there isn't a usable one.
    ///
    /// Below `minimumMarketCoverage` the market is discarded **wholesale** rather
    /// than used to anchor part of a race. A book missing several runners is not a
    /// book, and de-vigging what remains would quietly inflate everyone else.
    ///
    /// Above the threshold, a runner with no price takes the smallest priced
    /// probability in the race. It is an assumption, and a conservative one: a
    /// runner the market has not priced is not one it fancies. Stated here rather
    /// than hidden, because it is a guess.
    func marketAnchor(for runners: [Runner], market: MarketSnapshot?) -> MarketAnchor {
        let uniform = Array(repeating: 1 / Double(runners.count), count: runners.count)

        guard let market else {
            return MarketAnchor(probabilities: uniform, coverage: 0, isUsable: false)
        }

        let raw = runners.map { runner -> Double? in
            guard let price = market.price(for: runner.id) else { return nil }
            return Overround.impliedProbability(price)
        }
        let priced = raw.compactMap { $0 }
        let coverage = Double(priced.count) / Double(runners.count)

        guard coverage >= weights.minimumMarketCoverage, let floor = priced.min() else {
            return MarketAnchor(probabilities: uniform, coverage: coverage, isUsable: false)
        }

        let filled = raw.map { $0 ?? floor }
        let normalised = Overround.normalise(filled, method: weights.overroundMethod)
            .map { $0 ?? 1 / Double(runners.count) }

        return MarketAnchor(probabilities: normalised, coverage: coverage, isUsable: true)
    }

    /// `pᵢ ∝ p_marketᵢ^α · exp(β · formScoreᵢ)`, computed in log space.
    ///
    /// Working in logs and subtracting the maximum before exponentiating keeps
    /// large form scores from overflowing, which matters because the result of an
    /// overflow would be a silent `NaN` tip rather than a crash.
    static func combine(
        marketProbabilities: [Double],
        formScores: [Double],
        marketExponent: Double,
        formInfluence: Double
    ) -> [Double] {
        let count = marketProbabilities.count
        guard count > 0 else { return [] }

        let logScores = (0..<count).map { index -> Double in
            let probability = max(marketProbabilities[index], 1e-12)
            return marketExponent * log(probability) + formInfluence * formScores[index]
        }

        let peak = logScores.max() ?? 0
        let exponentiated = logScores.map { exp($0 - peak) }
        let total = exponentiated.reduce(0, +)

        guard total > 0, total.isFinite else {
            return Array(repeating: 1 / Double(count), count: count)
        }
        return exponentiated.map { $0 / total }
    }

    /// Each factor's effect, measured by neutralising it and re-rating.
    ///
    /// These deltas do **not** sum to the total deviation from the market — the
    /// renormaliser is nonlinear. So the UI labels them "effect on win chance" and
    /// anchors the display on the market probability and the final probability,
    /// rather than implying the middle rows add up. Pretending otherwise would be
    /// a small lie that compounds.
    func leaveOneOutDeltas(
        readings: [FactorReading],
        baseline: [Double],
        anchor: MarketAnchor,
        influence: Double,
        runnerCount: Int
    ) -> [FactorID: [Double]] {
        var deltas: [FactorID: [Double]] = [:]

        for reading in readings where reading.weight != 0 {
            let without = readings.filter { $0.id != reading.id }
            let scores = Self.formScores(without, count: runnerCount)
            let probabilities = Self.combine(
                marketProbabilities: anchor.probabilities,
                formScores: scores,
                marketExponent: weights.marketExponent,
                formInfluence: influence
            )
            deltas[reading.id] = (0..<runnerCount).map { baseline[$0] - probabilities[$0] }
        }
        return deltas
    }

    /// How concentrated the rating is, tempered by how much market data backed it.
    ///
    /// A near-uniform spread over twelve runners is a low-confidence race however
    /// the numbers were arrived at, and a well-separated favourite in a race we
    /// could not price is not as solid as it looks.
    static func confidence(of probabilities: [Double], coverage: Double) -> AssessmentConfidence {
        guard probabilities.count > 1 else { return .low }

        let entropy = -probabilities.reduce(0) { total, probability in
            probability > 0 ? total + probability * log(probability) : total
        }
        let maximumEntropy = log(Double(probabilities.count))
        guard maximumEntropy > 0 else { return .low }

        let concentration = 1 - entropy / maximumEntropy
        let sorted = probabilities.sorted(by: >)
        let margin = sorted[0] - sorted[1]

        let score = concentration * 0.6 + margin * 0.4 + (coverage > 0 ? 0.1 : 0)

        switch score {
        case ..<0.15: return .low
        case 0.15..<0.30: return .medium
        default: return .high
        }
    }
}
