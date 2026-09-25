import Foundation
@testable import Races
import RacesKit

/// The Races server, scripted. `@unchecked Sendable` with a lock rather than
/// an actor, because `RacesServing` is a class-bound protocol called across an
/// isolation boundary — a lock keeps the call counters honest without making
/// every assertion `await`.
///
/// Every result defaults to a failure that says it was not scripted, so a test
/// that reaches an endpoint it did not expect fails loudly rather than getting
/// an empty success that looks like "no racing".
final class FakeRacesServer: RacesServing, @unchecked Sendable {
    private let lock = NSLock()

    private var _racecards: [RaceDay: Result<ServerRacecard, APIError>]
    private var _race: Result<ServerRaceDetail, APIError>
    private var _record: Result<ServerRecord, APIError>
    private var _model: Result<ServerModel, APIError>
    private var _status: Result<ServerStatus, APIError>
    private var _courses: Result<[Course], APIError>
    private var _import: Result<ServerImportSummary, APIError>

    private var _racecardCalls = 0
    private var _jobs: [String] = []
    private var _recordRequests: [String?] = []
    private var _uploads: [ServerHistoryUpload] = []

    static let unscripted = APIError.server(status: 599, serverMessage: "FakeRacesServer: not scripted")

    init(
        racecards: [RaceDay: Result<ServerRacecard, APIError>] = [:],
        race: Result<ServerRaceDetail, APIError> = .failure(FakeRacesServer.unscripted),
        record: Result<ServerRecord, APIError> = .failure(FakeRacesServer.unscripted),
        model: Result<ServerModel, APIError> = .failure(FakeRacesServer.unscripted),
        status: Result<ServerStatus, APIError> = .failure(FakeRacesServer.unscripted),
        courses: Result<[Course], APIError> = .failure(FakeRacesServer.unscripted),
        importSummary: Result<ServerImportSummary, APIError> = .failure(FakeRacesServer.unscripted)
    ) {
        self._racecards = racecards
        self._race = race
        self._record = record
        self._model = model
        self._status = status
        self._courses = courses
        self._import = importSummary
    }

    var racecardCalls: Int { lock.withLock { _racecardCalls } }
    var jobs: [String] { lock.withLock { _jobs } }
    var recordRequests: [String?] { lock.withLock { _recordRequests } }
    var uploads: [ServerHistoryUpload] { lock.withLock { _uploads } }

    func setRacecard(_ result: Result<ServerRacecard, APIError>, for day: RaceDay = .today) {
        lock.withLock { _racecards[day] = result }
    }

    func setRecord(_ result: Result<ServerRecord, APIError>) {
        lock.withLock { _record = result }
    }

    func status() async throws -> ServerStatus { try lock.withLock { _status }.get() }
    func courses() async throws -> [Course] { try lock.withLock { _courses }.get() }

    func racecard(day: RaceDay) async throws -> ServerRacecard {
        let result = lock.withLock { () -> Result<ServerRacecard, APIError> in
            _racecardCalls += 1
            return _racecards[day] ?? .failure(Self.unscripted)
        }
        return try result.get()
    }

    func race(id: String) async throws -> ServerRaceDetail { try lock.withLock { _race }.get() }
    func record(weightsID: String?) async throws -> ServerRecord {
        let result = lock.withLock { () -> Result<ServerRecord, APIError> in
            _recordRequests.append(weightsID)
            return _record
        }
        return try result.get()
    }
    func model() async throws -> ServerModel { try lock.withLock { _model }.get() }

    func importHistory(_ upload: ServerHistoryUpload) async throws -> ServerImportSummary {
        let result = lock.withLock { () -> Result<ServerImportSummary, APIError> in
            _uploads.append(upload)
            return _import
        }
        return try result.get()
    }

    func runJob(_ name: String) async throws {
        lock.withLock { _jobs.append(name) }
    }
}

/// In-memory credentials, so `AppEnvironment` and `SettingsViewModel` are testable
/// without a signed container. The real Keychain returns `errSecMissingEntitlement`
/// in an unsigned test host.
final class InMemoryCredentialsStore: CredentialsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CredentialSlot: String]
    /// When set, every operation throws it — for the "broken Keychain" path.
    var failure: Error?

    init(_ initial: [CredentialSlot: String] = [:], failure: Error? = nil) {
        self.storage = initial
        self.failure = failure
    }

    func read(_ slot: CredentialSlot) throws -> String? {
        if let failure { throw failure }
        return lock.withLock { storage[slot] }
    }

    func write(_ value: String?, to slot: CredentialSlot) throws {
        if let failure { throw failure }
        lock.withLock {
            if let value, !value.isEmpty {
                storage[slot] = value
            } else {
                storage.removeValue(forKey: slot)
            }
        }
    }

    func removeAll() throws {
        if let failure { throw failure }
        lock.withLock { storage.removeAll() }
    }

    var slots: [CredentialSlot: String] { lock.withLock { storage } }
}

// MARK: - Builders

extension Race {
    /// A race with only the fields a browse test cares about.
    static func fixture(
        id: String = "rac_1",
        courseName: String = "Ascot",
        name: String = "Queen Anne Stakes",
        offTime: String = "2:30",
        offDateTime: Date? = nil,
        date: String = "2026-06-16",
        runners: [Runner] = []
    ) -> Race {
        Race(
            id: id,
            courseName: courseName,
            name: name,
            offTime: offTime,
            offDateTime: offDateTime,
            date: date,
            runners: runners)
    }
}

extension Course {
    static func fixture(
        id: String = "crs_1",
        name: String = "Ascot",
        regionCode: String = "gb",
        region: String = "Great Britain"
    ) -> Course {
        Course(id: id, name: name, regionCode: regionCode, region: region)
    }
}

/// A counter safe to touch from an escaping closure.
///
/// Capturing a mutable local in one and mutating it is what you reach for first,
/// and it is a data race the compiler is entitled to reject.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

extension Runner {
    static func fixture(
        id: String = "hrs_1",
        name: String = "Frankel",
        clothNumber: Int? = 1,
        officialRating: Int? = 100,
        form: String? = "1111",
        jockeyID: String? = "joc_1",
        trainerID: String? = "trn_1"
    ) -> Runner {
        Runner(
            id: id,
            name: name,
            clothNumber: clothNumber,
            officialRating: officialRating,
            form: form,
            jockeyID: jockeyID,
            jockeyName: "A Jockey",
            trainerID: trainerID,
            trainerName: "A Trainer")
    }
}

extension RaceResult {
    /// **A result used for settling needs at least three finishers.**
    /// `RaceResult.didRun(horseID:)` returns `nil` below that, on purpose: a
    /// truncated payload would otherwise settle every runner as a non-runner and
    /// wipe a day's tips in one pass. A two-runner fixture therefore leaves the
    /// tip `.unresolved` rather than won or lost, which looks like a bug in the
    /// store and is actually the guard working. Use `settleable(winner:)` unless
    /// the test is specifically about a short field.
    static func fixture(
        id: String = "rac_1",
        courseName: String = "Ascot",
        date: String = "2026-06-16",
        finishers: [Finisher]
    ) -> RaceResult {
        RaceResult(
            id: id,
            courseName: courseName,
            name: "A Race",
            date: date,
            offDateTime: nil,
            distance: nil,
            going: .unknown,
            surface: .unknown,
            type: .unknown,
            raceClass: nil,
            finishers: finishers)
    }
}

extension Finisher {
    static func fixture(
        horseID: String,
        position: Int,
        jockeyID: String? = "joc_1",
        trainerID: String? = "trn_1",
        startingPriceDecimal: Double? = nil
    ) -> Finisher {
        Finisher(
            horseID: horseID,
            horseName: horseID.uppercased(),
            position: FinishPosition(raw: "\(position)"),
            clothNumber: nil,
            draw: nil,
            weightPounds: nil,
            officialRating: nil,
            jockeyID: jockeyID,
            trainerID: trainerID,
            startingPriceDecimal: startingPriceDecimal)
    }
}

extension RaceResult {
    /// A result that `didRun` will actually answer: the given winner plus enough
    /// also-rans to clear the three-finisher floor.
    static func settleable(
        id: String = "rac_1",
        winner: String,
        alsoRan: [String] = ["also_1", "also_2"]
    ) -> RaceResult {
        var finishers = [Finisher.fixture(horseID: winner, position: 1)]
        for (index, horseID) in alsoRan.enumerated() {
            finishers.append(.fixture(horseID: horseID, position: index + 2))
        }
        return .fixture(id: id, finishers: finishers)
    }

    /// The same field, with the named horse beaten rather than winning.
    static func settleableLoss(
        id: String = "rac_1",
        loser: String,
        winner: String = "other_winner"
    ) -> RaceResult {
        .fixture(id: id, finishers: [
            .fixture(horseID: winner, position: 1),
            .fixture(horseID: "also_1", position: 2),
            .fixture(horseID: loser, position: 5),
        ])
    }
}

extension ServerRacecard {
    /// A day's card with assessments rated by the kit's own rater — the same
    /// numbers the server's Go port produces, as ServerParityTests pins.
    static func fixture(
        day: RaceDay = .today,
        date: String = "2026-06-16",
        races: [Race],
        market: [String: MarketSnapshot] = [:],
        sealed: Set<String> = [],
        archivedRaces: Int = 0,
        fetchedAt: Date? = nil
    ) -> ServerRacecard {
        var assessments: [String: RaceAssessment] = [:]
        var tips: [String: TipRecord] = [:]
        let now = Date(timeIntervalSince1970: 0)
        for race in races {
            let assessment = RaceRater(weights: .v2).rate(race, market: market[race.id], now: now)
            assessments[race.id] = assessment
            if var tip = TipRecord(assessment: assessment, race: race, now: now) {
                if sealed.contains(race.id) { tip.sealedAt = now }
                tips[race.id] = tip
            }
        }
        return ServerRacecard(
            day: day, date: date, fetchedAt: fetchedAt, races: races,
            assessments: assessments, tips: tips, archivedRaces: archivedRaces)
    }
}

extension ServerRecord {
    static func fixture(
        tips: [TipRecord] = [],
        sources: [String: Int] = [:],
        archivedRaces: Int = 0,
        weightsInUse: [String: Int] = [:],
        activeWeightsID: String? = nil
    ) -> ServerRecord {
        ServerRecord(
            activeWeightsID: activeWeightsID,
            report: AccuracyCalculator.report(for: tips),
            weightsInUse: weightsInUse,
            sources: sources,
            archivedRaces: archivedRaces)
    }
}

extension ServerImportSummary {
    /// Decoded, because the server is the only thing that ever builds one.
    static func fixture(tipsAdded: Int = 3, tipsKept: Int = 0) -> ServerImportSummary {
        let json = """
        {"device":"phone","tipsReceived":\(tipsAdded + tipsKept),"tipsAdded":\(tipsAdded),"tipsReplaced":0,
         "tipsKept":\(tipsKept),"archiveRacesAdded":0,"archiveSkipped":false,"samplesReceived":0,
         "samplesAdded":0,"pendingAdded":0,"weightsAdded":[],"unreadableDocuments":[]}
        """
        // A literal the test controls; force-unwrapping it is a test bug, not
        // a runtime path.
        return try! RacesServerClient.decoder.decode(ServerImportSummary.self, from: Data(json.utf8))
    }
}

extension ServerStatus {
    static func fixture(betfairConfigured: Bool = true) -> ServerStatus {
        ServerStatus(
            racingAPI: ServerProviderStatus(configured: true, healthy: true),
            betfair: ServerProviderStatus(configured: betfairConfigured, healthy: betfairConfigured),
            counts: ["tips": 12, "results": 40])
    }
}

/// A `LegacyHistory` over a fresh temporary directory, optionally seeded with
/// documents.
func temporaryHistory(documents: [String: String] = [:]) throws -> LegacyHistory {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("races-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, body) in documents {
        try Data(body.utf8).write(to: directory.appendingPathComponent(name))
    }
    return LegacyHistory(directory: directory)
}
