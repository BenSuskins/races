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

    public struct RecentRun: Codable, Hashable, Sendable {
        public let date: String
        public let raceID: String
        public let horseID: String
        public let won: Bool
    }

    public private(set) var jockeys: [String: StrikeRate]
    public private(set) var trainers: [String: StrikeRate]
    public private(set) var jockeySurfaces: [String: StrikeRate]
    public private(set) var trainerSurfaces: [String: StrikeRate]
    public private(set) var jockeyRaceTypes: [String: StrikeRate]
    public private(set) var trainerRaceTypes: [String: StrikeRate]
    public private(set) var jockeyGoings: [String: StrikeRate]
    public private(set) var trainerGoings: [String: StrikeRate]
    public private(set) var horseGoing: [String: HorseGoingPlaceRate]
    public private(set) var horseOverall: [String: HorseGoingPlaceRate]
    public private(set) var jockeyRecent: [String: [RecentRun]]
    public private(set) var trainerRecent: [String: [RecentRun]]
    public private(set) var jockeyTrainerPairs: [String: StrikeRate]
    public private(set) var drawBias: [String: DrawBiasRate]
    public private(set) var horseClass: [String: [ClassRun]]
    public private(set) var ingestedRaceIDs: Set<String>
    public private(set) var totalRuns: Int
    public private(set) var totalWins: Int

    private enum CodingKeys: String, CodingKey {
        case jockeys, trainers, jockeySurfaces, trainerSurfaces, jockeyRaceTypes, trainerRaceTypes, jockeyGoings, trainerGoings, horseGoing, horseOverall, jockeyRecent, trainerRecent, jockeyTrainerPairs, drawBias, horseClass, ingestedRaceIDs, totalRuns, totalWins
    }

    public init(
        jockeys: [String: StrikeRate] = [:],
        trainers: [String: StrikeRate] = [:],
        jockeySurfaces: [String: StrikeRate] = [:],
        trainerSurfaces: [String: StrikeRate] = [:],
        jockeyRaceTypes: [String: StrikeRate] = [:],
        trainerRaceTypes: [String: StrikeRate] = [:],
        jockeyGoings: [String: StrikeRate] = [:],
        trainerGoings: [String: StrikeRate] = [:],
        horseGoing: [String: HorseGoingPlaceRate] = [:],
        horseOverall: [String: HorseGoingPlaceRate] = [:],
        jockeyRecent: [String: [RecentRun]] = [:],
        trainerRecent: [String: [RecentRun]] = [:],
        jockeyTrainerPairs: [String: StrikeRate] = [:],
        drawBias: [String: DrawBiasRate] = [:],
        horseClass: [String: [ClassRun]] = [:],
        ingestedRaceIDs: Set<String> = [],
        totalRuns: Int = 0,
        totalWins: Int = 0
    ) {
        self.jockeys = jockeys
        self.trainers = trainers
        self.jockeySurfaces = jockeySurfaces
        self.trainerSurfaces = trainerSurfaces
        self.jockeyRaceTypes = jockeyRaceTypes
        self.trainerRaceTypes = trainerRaceTypes
        self.jockeyGoings = jockeyGoings
        self.trainerGoings = trainerGoings
        self.horseGoing = horseGoing
        self.horseOverall = horseOverall
        self.jockeyRecent = jockeyRecent
        self.trainerRecent = trainerRecent
        self.jockeyTrainerPairs = jockeyTrainerPairs
        self.drawBias = drawBias
        self.horseClass = horseClass
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
            jockeyRaceTypes: try values.decodeIfPresent([String: StrikeRate].self, forKey: .jockeyRaceTypes) ?? [:],
            trainerRaceTypes: try values.decodeIfPresent([String: StrikeRate].self, forKey: .trainerRaceTypes) ?? [:],
            jockeyGoings: try values.decodeIfPresent([String: StrikeRate].self, forKey: .jockeyGoings) ?? [:],
            trainerGoings: try values.decodeIfPresent([String: StrikeRate].self, forKey: .trainerGoings) ?? [:],
            horseGoing: try values.decodeIfPresent([String: HorseGoingPlaceRate].self, forKey: .horseGoing) ?? [:],
            horseOverall: try values.decodeIfPresent([String: HorseGoingPlaceRate].self, forKey: .horseOverall) ?? [:],
            jockeyRecent: try values.decodeIfPresent([String: [RecentRun]].self, forKey: .jockeyRecent) ?? [:],
            trainerRecent: try values.decodeIfPresent([String: [RecentRun]].self, forKey: .trainerRecent) ?? [:],
            jockeyTrainerPairs: try values.decodeIfPresent([String: StrikeRate].self, forKey: .jockeyTrainerPairs) ?? [:],
            drawBias: try values.decodeIfPresent([String: DrawBiasRate].self, forKey: .drawBias) ?? [:],
            horseClass: try values.decodeIfPresent([String: [ClassRun]].self, forKey: .horseClass) ?? [:],
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
        try values.encode(jockeyRaceTypes, forKey: .jockeyRaceTypes)
        try values.encode(trainerRaceTypes, forKey: .trainerRaceTypes)
        try values.encode(jockeyGoings, forKey: .jockeyGoings)
        try values.encode(trainerGoings, forKey: .trainerGoings)
        try values.encode(horseGoing, forKey: .horseGoing)
        try values.encode(horseOverall, forKey: .horseOverall)
        try values.encode(jockeyRecent, forKey: .jockeyRecent)
        try values.encode(trainerRecent, forKey: .trainerRecent)
        try values.encode(jockeyTrainerPairs, forKey: .jockeyTrainerPairs)
        try values.encode(drawBias, forKey: .drawBias)
        try values.encode(horseClass, forKey: .horseClass)
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
            if let raceClass = result.raceClass, (1...7).contains(raceClass), result.finishers.count >= 2, Self.isISODate(result.date) {
                let score: Double
                if let position = finisher.position.numericPosition, (1...result.finishers.count).contains(position) {
                    score = 1 - Double(position - 1) / Double(result.finishers.count - 1)
                } else {
                    score = 0
                }
                let run = ClassRun(date: result.date, raceID: result.id, raceClass: raceClass, score: score)
                horseClass[finisher.horseID] = Self.appendClassRun(horseClass[finisher.horseID, default: []], run)
            }
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
                if result.type != .unknown {
                    let key = Self.raceTypeKey(id: jockeyID, raceType: result.type)
                    jockeyRaceTypes[key] = increment(jockeyRaceTypes[key], won: won)
                }
                if let bucket = result.going.bucket(on: result.surface) {
                    let key = Self.goingKey(id: jockeyID, surface: result.surface, bucket: bucket)
                    jockeyGoings[key] = increment(jockeyGoings[key], won: won)
                }
                if Self.isISODate(result.date) {
                    let run = RecentRun(date: result.date, raceID: result.id, horseID: finisher.horseID, won: won)
                    jockeyRecent[jockeyID] = Self.appendRecent(jockeyRecent[jockeyID, default: []], run)
                }
            }
            if let trainerID = finisher.trainerID {
                trainers[trainerID] = increment(trainers[trainerID], won: won)
                if result.surface != .unknown {
                    let key = Self.surfaceKey(id: trainerID, surface: result.surface)
                    trainerSurfaces[key] = increment(trainerSurfaces[key], won: won)
                }
                if result.type != .unknown {
                    let key = Self.raceTypeKey(id: trainerID, raceType: result.type)
                    trainerRaceTypes[key] = increment(trainerRaceTypes[key], won: won)
                }
                if let bucket = result.going.bucket(on: result.surface) {
                    let key = Self.goingKey(id: trainerID, surface: result.surface, bucket: bucket)
                    trainerGoings[key] = increment(trainerGoings[key], won: won)
                }
                if Self.isISODate(result.date) {
                    let run = RecentRun(date: result.date, raceID: result.id, horseID: finisher.horseID, won: won)
                    trainerRecent[trainerID] = Self.appendRecent(trainerRecent[trainerID, default: []], run)
                }
            }
            if let jockeyID = finisher.jockeyID, let trainerID = finisher.trainerID {
                let key = Self.jockeyTrainerKey(jockeyID: jockeyID, trainerID: trainerID)
                jockeyTrainerPairs[key] = increment(jockeyTrainerPairs[key], won: won)
            }
            if let draw = finisher.draw,
               let key = Self.drawBiasCellKey(courseName: result.courseName, distance: result.distance, surface: result.surface, going: result.going, fieldSize: result.finishers.count, draw: draw) {
                let current = drawBias[key] ?? DrawBiasRate(runs: 0, wins: 0, expectedWins: 0)
                drawBias[key] = DrawBiasRate(
                    runs: current.runs + 1,
                    wins: current.wins + (won ? 1 : 0),
                    expectedWins: current.expectedWins + 1 / Double(result.finishers.count)
                )
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

    private mutating func incrementHorseOverall(horseID: String, placed: Bool) {
        let existing = horseOverall[horseID]
        horseOverall[horseID] = HorseGoingPlaceRate(runs: (existing?.runs ?? 0) + 1, places: (existing?.places ?? 0) + (placed ? 1 : 0))
    }

    private mutating func incrementHorseGoing(horseID: String, surface: Surface, bucket: HorseGoingBucket, placed: Bool) {
        let key = Self.horseGoingKey(horseID: horseID, surface: surface, bucket: bucket)
        let existing = horseGoing[key]
        horseGoing[key] = HorseGoingPlaceRate(runs: (existing?.runs ?? 0) + 1, places: (existing?.places ?? 0) + (placed ? 1 : 0))
    }

    private static func surfaceKey(id: String, surface: Surface) -> String {
        "\(id)|\(surface.rawValue)"
    }

    private static func raceTypeKey(id: String, raceType: RaceType) -> String {
        "\(id)|\(raceType.rawValue)"
    }

    private static func goingKey(id: String, surface: Surface, bucket: HorseGoingBucket) -> String {
        "\(id)|\(surface.rawValue)|\(bucket.rawValue)"
    }

    private static func drawBiasCellKey(courseName: String, distance: Distance?, surface: Surface, going: Going, fieldSize: Int, draw: Int) -> String? {
        guard let distance, distance.furlongs > 0, distance.furlongs.isFinite,
              fieldSize >= 5, draw >= 1, draw <= fieldSize,
              !courseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let ground = going.bucket(on: surface) else { return nil }
        let distanceBand: String
        switch distance.furlongs {
        case ...6: distanceBand = "sprint"
        case ...8: distanceBand = "mile"
        case ...12: distanceBand = "middle"
        default: distanceBand = "staying"
        }
        let fieldBand: String
        switch fieldSize {
        case ...8: fieldBand = "5-8"
        case ...12: fieldBand = "9-12"
        case ...16: fieldBand = "13-16"
        default: fieldBand = "17+"
        }
        let drawBand: String
        if draw * 3 <= fieldSize { drawBand = "inside" }
        else if draw * 3 <= fieldSize * 2 { drawBand = "middle" }
        else { drawBand = "outside" }
        return [courseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), surface.rawValue, distanceBand, ground.rawValue, fieldBand, drawBand].joined(separator: "|")
    }

    private static func jockeyTrainerKey(jockeyID: String, trainerID: String) -> String {
        "\(jockeyID)|\(trainerID)"
    }

    private static func horseGoingKey(horseID: String, surface: Surface, bucket: HorseGoingBucket) -> String {
        "\(horseID)|\(surface.rawValue)|\(bucket.rawValue)"
    }

    private static func isISODate(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let parsed = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: parsed)
        return components.year == year && components.month == month && components.day == day
    }

    private static func appendRecent(_ recentRuns: [RecentRun], _ newRun: RecentRun) -> [RecentRun] {
        let sorted = (recentRuns + [newRun]).sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.raceID != $1.raceID { return $0.raceID < $1.raceID }
            return $0.horseID < $1.horseID
        }
        return Array(sorted.suffix(50))
    }

    private static func appendClassRun(_ classRuns: [ClassRun], _ newRun: ClassRun) -> [ClassRun] {
        let sorted = (classRuns + [newRun]).sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.raceID < $1.raceID
        }
        return Array(sorted.suffix(50))
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

extension ResultsArchive: RaceTypeStrikeRateProviding {
    public func jockeyRaceTypeStrikeRate(id: String, raceType: RaceType) -> StrikeRate? {
        jockeyRaceTypes[Self.raceTypeKey(id: id, raceType: raceType)]
    }

    public func trainerRaceTypeStrikeRate(id: String, raceType: RaceType) -> StrikeRate? {
        trainerRaceTypes[Self.raceTypeKey(id: id, raceType: raceType)]
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

extension ResultsArchive: GoingStrikeRateProviding {
    public func jockeyGoingStrikeRate(id: String, surface: Surface, bucket: HorseGoingBucket) -> StrikeRate? {
        jockeyGoings[Self.goingKey(id: id, surface: surface, bucket: bucket)]
    }

    public func trainerGoingStrikeRate(id: String, surface: Surface, bucket: HorseGoingBucket) -> StrikeRate? {
        trainerGoings[Self.goingKey(id: id, surface: surface, bucket: bucket)]
    }
}

extension ResultsArchive: RecentStrikeRateProviding {
    public func jockeyRecentStrikeRate(id: String) -> StrikeRate? { Self.rate(jockeyRecent[id]) }
    public func trainerRecentStrikeRate(id: String) -> StrikeRate? { Self.rate(trainerRecent[id]) }

    private static func rate(_ runs: [RecentRun]?) -> StrikeRate? {
        guard let runs, !runs.isEmpty else { return nil }
        return StrikeRate(runs: runs.count, wins: runs.filter(\.won).count)
    }
}

extension ResultsArchive: JockeyTrainerStrikeRateProviding {
    public func jockeyTrainerStrikeRate(jockeyID: String, trainerID: String) -> StrikeRate? {
        jockeyTrainerPairs[Self.jockeyTrainerKey(jockeyID: jockeyID, trainerID: trainerID)]
    }
}

extension ResultsArchive: DrawBiasProviding {
    public func drawBiasRate(race: Race, runner: Runner) -> DrawBiasRate? {
        guard let draw = runner.draw else { return nil }
        let fieldSize = race.fieldSize.flatMap { $0 > 0 ? $0 : nil } ?? race.runners.count
        guard let key = Self.drawBiasCellKey(courseName: race.courseName, distance: race.distance, surface: race.surface, going: race.going, fieldSize: fieldSize, draw: draw) else { return nil }
        return drawBias[key]
    }
}

extension ResultsArchive: ClassAdjustedFormProviding {
    public func horseClassFormRate(horseID: String, targetClass: Int) -> ClassAdjustedFormRate? {
        guard (1...7).contains(targetClass) else { return nil }
        var runs = 0
        var scoreTotal = 0.0
        for run in horseClass[horseID, default: []] {
            let adjustment = Double(targetClass - run.raceClass) * 0.04
            scoreTotal += min(1, max(0, run.score + adjustment))
            runs += 1
        }
        guard runs > 0 else { return nil }
        return ClassAdjustedFormRate(runs: runs, score: scoreTotal / Double(runs))
    }
}
