import Foundation

/// Strike rates accumulated from results the app has actually seen.
///
/// This is the quiet payoff of keeping history on device: it costs nothing extra
/// and gets better every day the app runs. It is also the one place where the
/// free tier can, given time, produce something a paid endpoint would otherwise
/// have to supply.
///
/// **Ingestion is idempotent.** The app re-fetches today's results repeatedly
/// through an afternoon, and counting the same race twice would inflate every
/// figure derived from it. `ingestedRaceIDs` is what prevents that, and it is the
/// single most important property of this type.
public struct ResultsArchive: Codable, Hashable, Sendable {

    public private(set) var jockeys: [String: StrikeRate]
    public private(set) var trainers: [String: StrikeRate]
    public private(set) var horseGoing: [String: HorseGoingPlaceRate]
    public private(set) var horseOverall: [String: HorseGoingPlaceRate]
    public private(set) var ingestedRaceIDs: Set<String>
    public private(set) var totalRuns: Int
    public private(set) var totalWins: Int

    private enum CodingKeys: String, CodingKey {
        case jockeys, trainers, horseGoing, horseOverall, ingestedRaceIDs, totalRuns, totalWins
    }

    public init(
        jockeys: [String: StrikeRate] = [:],
        trainers: [String: StrikeRate] = [:],
        horseGoing: [String: HorseGoingPlaceRate] = [:],
        horseOverall: [String: HorseGoingPlaceRate] = [:],
        ingestedRaceIDs: Set<String> = [],
        totalRuns: Int = 0,
        totalWins: Int = 0
    ) {
        self.jockeys = jockeys
        self.trainers = trainers
        self.horseGoing = horseGoing
        self.horseOverall = horseOverall
        self.ingestedRaceIDs = ingestedRaceIDs
        self.totalRuns = totalRuns
        self.totalWins = totalWins
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            jockeys: try values.decodeIfPresent([String: StrikeRate].self, forKey: .jockeys) ?? [:],
            trainers: try values.decodeIfPresent([String: StrikeRate].self, forKey: .trainers) ?? [:],
            horseGoing: try values.decodeIfPresent([String: HorseGoingPlaceRate].self, forKey: .horseGoing) ?? [:],
            horseOverall: try values.decodeIfPresent([String: HorseGoingPlaceRate].self, forKey: .horseOverall) ?? [:],
            ingestedRaceIDs: try values.decodeIfPresent(Set<String>.self, forKey: .ingestedRaceIDs) ?? [],
            totalRuns: try values.decodeIfPresent(Int.self, forKey: .totalRuns) ?? 0,
            totalWins: try values.decodeIfPresent(Int.self, forKey: .totalWins) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(jockeys, forKey: .jockeys)
        try values.encode(trainers, forKey: .trainers)
        try values.encode(horseGoing, forKey: .horseGoing)
        try values.encode(horseOverall, forKey: .horseOverall)
        try values.encode(ingestedRaceIDs, forKey: .ingestedRaceIDs)
        try values.encode(totalRuns, forKey: .totalRuns)
        try values.encode(totalWins, forKey: .totalWins)
    }

    public var raceCount: Int { ingestedRaceIDs.count }

    /// Add a settled race. Returns false if it was already counted.
    @discardableResult
    public mutating func ingest(_ result: RaceResult) -> Bool {
        guard !ingestedRaceIDs.contains(result.id) else { return false }
        guard !result.finishers.isEmpty else { return false }

        ingestedRaceIDs.insert(result.id)

        for finisher in result.finishers {
            // A horse that pulled up still ran. Only actual participants are
            // counted, which is exactly what the finishers list holds.
            let won = finisher.position.isWinner
            totalRuns += 1
            if won { totalWins += 1 }

            if let jockeyID = finisher.jockeyID {
                jockeys[jockeyID] = increment(jockeys[jockeyID], won: won)
            }
            if let trainerID = finisher.trainerID {
                trainers[trainerID] = increment(trainers[trainerID], won: won)
            }

            if let position = finisher.position.numericPosition {
                incrementHorseOverall(horseID: finisher.horseID, placed: position <= 3)
                if let bucket = result.going.bucket(on: result.surface) {
                    incrementHorseGoing(horseID: finisher.horseID, surface: result.surface, bucket: bucket, placed: position <= 3)
                }
            }
        }
        return true
    }

    @discardableResult
    public mutating func ingest(_ results: [RaceResult]) -> Int {
        results.reduce(into: 0) { count, result in
            if ingest(result) { count += 1 }
        }
    }

    private func increment(_ existing: StrikeRate?, won: Bool) -> StrikeRate {
        StrikeRate(
            runs: (existing?.runs ?? 0) + 1,
            wins: (existing?.wins ?? 0) + (won ? 1 : 0)
        )
    }

    private mutating func incrementHorseGoing(horseID: String, surface: Surface, bucket: HorseGoingBucket, placed: Bool) {
        let key = Self.horseGoingKey(horseID: horseID, surface: surface, bucket: bucket)
        let existing = horseGoing[key]
        horseGoing[key] = HorseGoingPlaceRate(runs: (existing?.runs ?? 0) + 1, places: (existing?.places ?? 0) + (placed ? 1 : 0))
    }

    private mutating func incrementHorseOverall(horseID: String, placed: Bool) {
        let existing = horseOverall[horseID]
        horseOverall[horseID] = HorseGoingPlaceRate(runs: (existing?.runs ?? 0) + 1, places: (existing?.places ?? 0) + (placed ? 1 : 0))
    }

    private static func horseGoingKey(horseID: String, surface: Surface, bucket: HorseGoingBucket) -> String {
        "\(horseID)|\(surface.rawValue)|\(bucket.rawValue)"
    }
}

extension ResultsArchive: StrikeRateProviding {

    public func jockeyStrikeRate(id: String) -> StrikeRate? {
        jockeys[id]
    }

    public func trainerStrikeRate(id: String) -> StrikeRate? {
        trainers[id]
    }

    /// The population strike rate, which small samples are shrunk toward.
    ///
    /// Falls back to 1/8 — roughly an average British field — until there is
    /// enough archive to measure it. Guessing here is safe in a way that guessing
    /// a draw bias is not: it only affects how hard a thin record is pulled back
    /// toward the middle.
    public var baselineStrikeRate: Double {
        guard totalRuns >= 100 else { return 0.125 }
        return Double(totalWins) / Double(totalRuns)
    }
}

extension ResultsArchive: HorseGoingProviding {
    public func horseGoingRate(horseID: String, surface: Surface, bucket: HorseGoingBucket) -> HorseGoingPlaceRate? {
        horseGoing[Self.horseGoingKey(horseID: horseID, surface: surface, bucket: bucket)]
    }

    public func horseOverallPlaceRate(horseID: String) -> HorseGoingPlaceRate? {
        horseOverall[horseID]
    }
}
