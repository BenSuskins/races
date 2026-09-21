import Foundation
@testable import Races
import RacesKit

/// Scripted provider. `@unchecked Sendable` with a lock rather than an actor,
/// because `RacingDataProviding` is a class-bound protocol and the view models
/// call it across an isolation boundary — a lock keeps the call counters honest
/// without making every assertion `await`.
final class FakeRacingDataProvider: RacingDataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _racecardCalls = 0
    private var _coursesCalls = 0

    var racecardCalls: Int { lock.withLock { _racecardCalls } }
    var coursesCalls: Int { lock.withLock { _coursesCalls } }
    /// Region codes from the most recent racecards call.
    private var _lastRegionCodes: [String] = []
    var lastRegionCodes: [String] { lock.withLock { _lastRegionCodes } }

    private let coursesResult: Result<[Course], APIError>
    private let racecardsResult: Result<[Race], APIError>
    private let resultsResult: Result<[RaceResult], APIError>
    private let capabilityValue: ProviderCapability

    private var _resultsCalls = 0
    var resultsCalls: Int { lock.withLock { _resultsCalls } }

    init(
        courses: Result<[Course], APIError> = .success([]),
        racecards: Result<[Race], APIError> = .success([]),
        results: Result<[RaceResult], APIError> = .success([]),
        capability: ProviderCapability = .free
    ) {
        self.coursesResult = courses
        self.racecardsResult = racecards
        self.resultsResult = results
        self.capabilityValue = capability
    }

    var capability: ProviderCapability {
        get async { capabilityValue }
    }

    func courses(regionCodes: [String]) async throws -> [Course] {
        lock.withLock { _coursesCalls += 1 }
        return try coursesResult.get()
    }

    func racecards(day: RaceDay, regionCodes: [String]) async throws -> [Race] {
        lock.withLock {
            _racecardCalls += 1
            _lastRegionCodes = regionCodes
        }
        return try racecardsResult.get()
    }

    func results(day: RaceDay) async throws -> [RaceResult] {
        lock.withLock { _resultsCalls += 1 }
        return try resultsResult.get()
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
