import Foundation
import RacesKit

nonisolated enum StoreDocument {
    static let tips = "tips.json"
    static let archive = "archive.json"
    static let training = "training.json"
    static func racecards(day: String) -> String { "racecards-\(day).json" }
    static let racecardFreshness: TimeInterval = 15 * 60
}

nonisolated struct ResultsIngestion: Hashable, Sendable {
    var newRacesArchived: Int = 0
    var tipsSettled: Int = 0
    var modelRetrained: Bool = false
    var changedAnything: Bool { newRacesArchived > 0 || tipsSettled > 0 || modelRetrained }
}

nonisolated struct CachedRacecards: Codable, Hashable, Sendable {
    let fetchedAt: Date
    let races: [Race]
}

/// Persistent state for the on-device learner. Training inputs are frozen at tip
/// time and only receive a winner after a result has settled.
nonisolated struct OnDeviceTrainingState: Codable, Hashable, Sendable {
    var samples: [TrainingRace]
    var pendingSnapshots: [String: TrainingRaceSnapshot]
    var activeWeights: RatingWeights
    var lastTrainingSampleCount: Int
    var configuration: WeightTrainingConfiguration

    init(
        activeWeights: RatingWeights = .v1,
        configuration: WeightTrainingConfiguration = .init()
    ) {
        self.samples = []
        self.pendingSnapshots = [:]
        self.activeWeights = activeWeights
        self.lastTrainingSampleCount = 0
        self.configuration = configuration
    }

    mutating func add(snapshot: TrainingRaceSnapshot, winnerID: String) {
        guard !samples.contains(where: { $0.snapshot.raceID == snapshot.raceID }),
              snapshot.runnerIDs.contains(winnerID) else { return }
        samples.append(TrainingRace(snapshot: snapshot, winnerID: winnerID))
        pendingSnapshots.removeValue(forKey: snapshot.raceID)
    }

    var settledCount: Int { samples.count }
}

actor RacesStore {

    private let documents: any DocumentStoring
    private var rater: RaceRater
    private var ledger = TipLedger()
    private var archive = ResultsArchive()
    private var training = OnDeviceTrainingState()
    private var hasLoaded = false

    init(documents: any DocumentStoring, rater: RaceRater = RaceRater()) {
        self.documents = documents
        self.rater = rater
        self.training = OnDeviceTrainingState(activeWeights: rater.weights)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        ledger = await load(TipLedger.self, from: StoreDocument.tips) ?? TipLedger()
        archive = await load(ResultsArchive.self, from: StoreDocument.archive) ?? ResultsArchive()
        training = await load(OnDeviceTrainingState.self, from: StoreDocument.training)
            ?? OnDeviceTrainingState(activeWeights: rater.weights)
        rater = RaceRater(weights: training.activeWeights)
    }

    private func load<T: Codable & Sendable>(_ type: T.Type, from name: String) async -> T? {
        do { return try await documents.load(type, from: name) } catch { return nil }
    }

    var tips: [TipRecord] { ledger.tips }
    var archivedRaceCount: Int { archive.raceCount }
    var hasArchive: Bool { archive.raceCount > 0 }
    var activeWeights: RatingWeights { training.activeWeights }
    var trainingRaceCount: Int { training.settledCount }

    func marketIDsAwaitingStartingPrice(now: Date = Date()) -> [String] {
        ledger.marketIDsAwaitingStartingPrice(now: now)
    }

    func report(commission: Double = AccuracyCalculator.defaultCommission) -> AccuracyReport {
        AccuracyCalculator.report(for: ledger.tips, commission: commission)
    }

    func tip(forRace raceID: String) -> TipRecord? { ledger.tip(forRace: raceID) }

    func assess(
        _ race: Race,
        market: MarketSnapshot? = nil,
        now: Date = Date()
    ) -> RaceAssessment {
        rater.rate(race, market: market, strikeRates: archive, now: now)
    }

    @discardableResult
    func assessAndRecord(
        _ races: [Race],
        markets: [String: MarketSnapshot] = [:],
        references: [String: MarketReference] = [:],
        now: Date = Date()
    ) async -> [String: RaceAssessment] {
        var assessments: [String: RaceAssessment] = [:]
        var stored = false
        var trainingChanged = false

        for race in races {
            let assessment = assess(race, market: markets[race.id], now: now)
            assessments[race.id] = assessment
            if let snapshot = assessment.trainingSnapshot {
                training.pendingSnapshots[race.id] = snapshot
                trainingChanged = true
            }
            if ledger.record(
                assessment,
                race: race,
                marketReference: references[race.id],
                now: now
            ).didStore {
                stored = true
            }
        }

        if stored { await persistLedger() }
        if trainingChanged { await persistTraining() }
        return assessments
    }

    @discardableResult
    func ingest(
        results: [RaceResult],
        startingPrices: [String: [Int64: Double]] = [:],
        now: Date = Date()
    ) async -> ResultsIngestion {
        var ingestion = ResultsIngestion()
        ingestion.newRacesArchived = archive.ingest(results)

        let resultsByRaceID = Dictionary(
            results.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        for tip in ledger.awaitingReconciliation(now: now) {
            let betfairSPs = tip.marketReference?.startingPrices(from: startingPrices) ?? [:]
            let settled = ResultReconciler.settle(
                tip: tip,
                result: resultsByRaceID[tip.raceID],
                betfairStartingPrices: betfairSPs,
                now: now)
            guard settled != tip else { continue }
            ledger.replace(settled)
            if settled.outcome?.isSettled == true || settled.outcome?.isVoid == true {
                ingestion.tipsSettled += 1
            }

            if settled.outcome?.isSettled == true,
               let result = resultsByRaceID[tip.raceID],
               let winner = result.winner,
               let snapshot = training.pendingSnapshots[tip.raceID] {
                training.add(snapshot: snapshot, winnerID: winner.horseID)
            }
        }

        if ingestion.newRacesArchived > 0 { await persistArchive() }
        if ingestion.tipsSettled > 0 || !ledger.awaitingReconciliation(now: now).isEmpty {
            await persistLedger()
        }

        if shouldRetrain {
            let report = OnDeviceWeightTrainer.train(
                samples: training.samples,
                current: training.activeWeights,
                configuration: training.configuration
            )
            training.lastTrainingSampleCount = training.settledCount
            if report.promoted {
                training.activeWeights = report.weights
                rater = RaceRater(weights: report.weights)
                ingestion.modelRetrained = true
            }
            await persistTraining()
        } else if ingestion.tipsSettled > 0 {
            await persistTraining()
        }

        return ingestion
    }

    private var shouldRetrain: Bool {
        let threshold = training.configuration.minimumRaces
        guard training.settledCount >= threshold else { return false }
        return training.settledCount - training.lastTrainingSampleCount >= threshold
    }

    func cachedRacecards(day: String) async -> CachedRacecards? {
        await load(CachedRacecards.self, from: StoreDocument.racecards(day: day))
    }

    func saveRacecards(_ races: [Race], day: String, fetchedAt: Date = Date()) async {
        let cached = CachedRacecards(fetchedAt: fetchedAt, races: races)
        try? await documents.save(cached, to: StoreDocument.racecards(day: day))
    }

    private func persistLedger() async {
        try? await documents.save(ledger, to: StoreDocument.tips)
    }

    private func persistArchive() async {
        try? await documents.save(archive, to: StoreDocument.archive)
    }

    private func persistTraining() async {
        try? await documents.save(training, to: StoreDocument.training)
    }

    func clearHistory() async {
        ledger = TipLedger()
        archive = ResultsArchive()
        training = OnDeviceTrainingState(activeWeights: .v1)
        rater = RaceRater(weights: .v1)
        try? await documents.delete(StoreDocument.tips)
        try? await documents.delete(StoreDocument.archive)
        try? await documents.delete(StoreDocument.training)
    }
}
