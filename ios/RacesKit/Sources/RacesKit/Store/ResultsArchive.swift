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
    public private(set) var jockeySurfaces: [String: StrikeRate]
    public private(set) var trainerSurfaces: [String: StrikeRate]
    public private(set) var ingestedRaceIDs: Set<String>
    public private(set) var totalRuns: Int
    public private(set) var totalWins: Int

    private enum CodingKeys: String, CodingKey {
        case jockeys, trainers, jockeySurfaces, trainerSurfaces, ingestedRaceIDs, totalRuns, totalWins
    }

    public init(
        jockeys: [String: StrikeRate] = [:],
        trainers: [String: StrikeRate] = [:],
        jockeySurfaces: [String: StrikeRate] = [:],
        trainerSurfaces: [String: StrikeRate] = [:],
        ingestedRaceIDs: Set<String> = [],
        totalRuns: Int = 0,
        totalWins: Int = 0
    ) {
        self.jockeys = jockeys
        self.trainers = trainers
        self.jockeySurfaces = jockeySurfaces
        self.trainerSurfaces = trainerSurfaces
        self.ingestedRaceIDs = ingestedRaceIDs
        self.totalRuns = totalRuns
        self.totalWins = totalWins
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            jockeys: try values.decodeIfPresent([String: StrikeRate].self, forKey: .jockeys) ?? [:],
            trainers: try values.decodeIfPresent([String: StrikeRate].self, forKey: .trainers) ?? [:],
            jockeySurfaces: try values.decodeIfPresent([String: StrikeRate].self, forKey: .jockeySurfaces) ?? [:],
            trainerSurfaces: try values.decodeIfPresent([String: StrikeRate].self, forKey: .trainerSurfaces) ?? [:],
            ingestedRaceIDs: try values.decodeIfPresent(Set<String>.self, forKey: .ingestedRaceIDs) ?? [],
            totalRuns: try values.decodeIfPresent(Int.self, forKey: .totalRuns) ?? 0,
            totalWins: try values.decodeIfPresent(Int.self, forKey: .totalWins) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(jockeys, forKey: .jockeys)
        try values.encode(trainers, forKey: .trainers)
        try values.encode(jockeySurfaces, forKey: .jockeySurfaces)
        try values.encode(trainerSurfaces, forKey: .trainerSurfaces)
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
                if result.surface != .unknown {
                    let key = Self.surfaceKey(id: jockeyID, surface: result.surface)
                    jockeySurfaces[key] = increment(jockeySurfaces[key], won: won)
                }
            }
            if let trainerID = finisher.trainerID {
                trainers[trainerID] = increment(trainers[trainerID], won: won)
                if result.surface != .unknown {
                    let key = Self.surfaceKey(id: trainerID, surface: result.surface)
                    trainerSurfaces[key] = increment(trainerSurfaces[key], won: won)
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

    private static func surfaceKey(id: String, surface: Surface) -> String {
        "\(id)|\(surface.rawValue)"
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

extension ResultsArchive: SurfaceStrikeRateProviding {
    public func jockeySurfaceStrikeRate(id: String, surface: Surface) -> StrikeRate? {
        jockeySurfaces[Self.surfaceKey(id: id, surface: surface)]
    }

    public func trainerSurfaceStrikeRate(id: String, surface: Surface) -> StrikeRate? {
        trainerSurfaces[Self.surfaceKey(id: id, surface: surface)]
    }
}
