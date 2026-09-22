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

/// Scripted exchange. Same shape and the same reasoning as
/// `FakeRacingDataProvider`: a lock rather than an actor, so a test can assert
/// call counts without awaiting.
///
/// The counters are the point of it — `MarketLoader` caches the catalogue and
/// the books separately, and a cache that quietly refetches is indistinguishable
/// from one that works unless the calls are counted.
final class FakeMarketDataProvider: MarketDataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _marketCalls = 0
    private var _priceCalls = 0
    private var _lastPricedMarketIDs: [String] = []

    var marketCalls: Int { lock.withLock { _marketCalls } }
    var priceCalls: Int { lock.withLock { _priceCalls } }
    var lastPricedMarketIDs: [String] { lock.withLock { _lastPricedMarketIDs } }

    private var _startingPriceCalls = 0
    private var _lastStartingPriceMarketIDs: [String] = []

    var startingPriceCalls: Int { lock.withLock { _startingPriceCalls } }
    var lastStartingPriceMarketIDs: [String] { lock.withLock { _lastStartingPriceMarketIDs } }

    private let marketsResult: Result<[ExchangeMarket], Error>
    private let pricesResult: Result<[ExchangeMarketPrices], Error>
    private let startingPricesResult: Result<[String: [Int64: Double]], Error>

    init(
        markets: Result<[ExchangeMarket], Error> = .success([]),
        prices: Result<[ExchangeMarketPrices], Error> = .success([]),
        startingPrices: Result<[String: [Int64: Double]], Error> = .success([:])
    ) {
        self.marketsResult = markets
        self.pricesResult = prices
        self.startingPricesResult = startingPrices
    }

    func markets(day: RaceDay, countries: [String]) async throws -> [ExchangeMarket] {
        lock.withLock { _marketCalls += 1 }
        return try marketsResult.get()
    }

    func prices(marketIDs: [String]) async throws -> [ExchangeMarketPrices] {
        lock.withLock {
            _priceCalls += 1
            _lastPricedMarketIDs = marketIDs.sorted()
        }
        // Only the books that were asked for, so a test cannot accidentally
        // pass because the fake handed back a market the loader never wanted.
        return try pricesResult.get().filter { marketIDs.contains($0.marketID) }
    }

    func startingPrices(marketIDs: [String]) async throws -> [String: [Int64: Double]] {
        lock.withLock {
            _startingPriceCalls += 1
            _lastStartingPriceMarketIDs = marketIDs.sorted()
        }
        return try startingPricesResult.get()
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

extension ExchangeMarket {
    /// A win market whose runners are the exchange's view of the given cloth
    /// numbers and names.
    ///
    /// `selectionID` is derived from the cloth number rather than passed in, so
    /// a test can state the field once and still assert the join landed on the
    /// right horse.
    static func fixture(
        id: String = "1.234",
        venue: String = "Ascot",
        startTime: Date,
        runners: [(clothNumber: Int, name: String)]
    ) -> ExchangeMarket {
        ExchangeMarket(
            id: id,
            venue: venue,
            startTime: startTime,
            marketName: "WIN",
            runners: runners.map {
                ExchangeRunner(
                    id: Int64(1_000 + $0.clothNumber),
                    name: $0.name,
                    clothNumber: $0.clothNumber)
            })
    }
}

extension ExchangeMarketPrices {
    /// A book priced by cloth number, matching `ExchangeMarket.fixture`'s
    /// selection ids.
    static func fixture(
        marketID: String = "1.234",
        capturedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        backPricesByClothNumber: [Int: Double]
    ) -> ExchangeMarketPrices {
        var prices: [Int64: RunnerPrice] = [:]
        for (clothNumber, backPrice) in backPricesByClothNumber {
            prices[Int64(1_000 + clothNumber)] = RunnerPrice(backPrice: backPrice)
        }
        return ExchangeMarketPrices(
            marketID: marketID,
            status: "OPEN",
            capturedAt: capturedAt,
            isDelayed: true,
            prices: prices)
    }
}
