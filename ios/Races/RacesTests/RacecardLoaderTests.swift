import XCTest
@testable import Races
import RacesKit

final class RacecardLoaderTests: XCTestCase {

    @MainActor
    private func makeLoader(
        _ provider: FakeRacingDataProvider?,
        store: RacesStore
    ) -> RacecardLoader {
        RacecardLoader(provider: provider, store: store)
    }

    @MainActor
    func test_aFreshCacheIsServedWithoutAskingTheProvider() async throws {
        let provider = FakeRacingDataProvider(racecards: .success([.fixture(id: "r1")]))
        let store = RacesStore(documents: InMemoryDocumentStore())
        let loader = makeLoader(provider, store: store)
        let start = Date(timeIntervalSince1970: 1_000_000)

        _ = try await loader.load(day: .today, now: start)
        XCTAssertEqual(provider.racecardCalls, 1)

        // Inside the window: a tab switch must not spend a request against the
        // 1 req/s free tier.
        let second = try await loader.load(
            day: .today, now: start.addingTimeInterval(StoreDocument.racecardFreshness - 1))

        XCTAssertEqual(provider.racecardCalls, 1)
        XCTAssertEqual(second.races.map(\.id), ["r1"])
        XCTAssertTrue(second.isFresh)
    }

    @MainActor
    func test_aStaleCacheIsRefreshed() async throws {
        let provider = FakeRacingDataProvider(racecards: .success([.fixture(id: "r1")]))
        let store = RacesStore(documents: InMemoryDocumentStore())
        let loader = makeLoader(provider, store: store)
        let start = Date(timeIntervalSince1970: 1_000_000)

        _ = try await loader.load(day: .today, now: start)
        _ = try await loader.load(
            day: .today, now: start.addingTimeInterval(StoreDocument.racecardFreshness + 1))

        XCTAssertEqual(provider.racecardCalls, 2)
    }

    @MainActor
    func test_forceRefreshIgnoresAFreshCache() async throws {
        let provider = FakeRacingDataProvider(racecards: .success([.fixture(id: "r1")]))
        let store = RacesStore(documents: InMemoryDocumentStore())
        let loader = makeLoader(provider, store: store)
        let start = Date(timeIntervalSince1970: 1_000_000)

        _ = try await loader.load(day: .today, now: start)
        // Pull to refresh exists for when the user knows better than the clock.
        _ = try await loader.load(day: .today, forceRefresh: true, now: start)

        XCTAssertEqual(provider.racecardCalls, 2)
    }

    @MainActor
    func test_aFailedRefreshFallsBackToTheCacheAndSaysSo() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        let start = Date(timeIntervalSince1970: 1_000_000)

        let working = makeLoader(
            FakeRacingDataProvider(racecards: .success([.fixture(id: "r1")])), store: store)
        _ = try await working.load(day: .today, now: start)

        let failing = makeLoader(
            FakeRacingDataProvider(racecards: .failure(.offline)), store: store)
        let load = try await failing.load(
            day: .today, now: start.addingTimeInterval(StoreDocument.racecardFreshness + 1))

        // A stale card beats an error screen — but only because the screen is
        // told it is stale and says when it was saved.
        XCTAssertEqual(load.races.map(\.id), ["r1"])
        XCTAssertFalse(load.isFresh)
        XCTAssertEqual(load.fetchedAt.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
    }

    @MainActor
    func test_aFailureWithNoCacheThrows() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        let loader = makeLoader(
            FakeRacingDataProvider(racecards: .failure(.offline)), store: store)

        do {
            _ = try await loader.load(day: .today, now: Date())
            XCTFail("Expected a throw with nothing cached")
        } catch {
            XCTAssertEqual(APIError.from(error), .offline)
        }
    }

    @MainActor
    func test_noProviderStillServesACachedCard() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        let start = Date(timeIntervalSince1970: 1_000_000)
        let working = makeLoader(
            FakeRacingDataProvider(racecards: .success([.fixture(id: "r1")])), store: store)
        _ = try await working.load(day: .today, now: start)

        // Credentials cleared. The card they last saw was real, so it is still
        // worth showing.
        let loader = makeLoader(nil, store: store)
        let load = try await loader.load(day: .today, now: start.addingTimeInterval(86_400))

        XCTAssertEqual(load.races.map(\.id), ["r1"])
        XCTAssertFalse(load.isFresh)
    }

    @MainActor
    func test_noProviderAndNoCacheReportsNotConfigured() async {
        let loader = makeLoader(nil, store: RacesStore(documents: InMemoryDocumentStore()))

        do {
            _ = try await loader.load(day: .today, now: Date())
            XCTFail("Expected notConfigured")
        } catch {
            XCTAssertTrue(APIError.from(error).isExpectedLimitation)
        }
    }

    @MainActor
    func test_todayAndTomorrowDoNotShareACacheEntry() async throws {
        let provider = FakeRacingDataProvider(racecards: .success([.fixture(id: "r1")]))
        let store = RacesStore(documents: InMemoryDocumentStore())
        let loader = makeLoader(provider, store: store)
        let start = Date(timeIntervalSince1970: 1_000_000)

        _ = try await loader.load(day: .today, now: start)
        _ = try await loader.load(day: .tomorrow, now: start)

        // Caching both under one key would show tomorrow's card as today's.
        XCTAssertEqual(provider.racecardCalls, 2)
    }

    @MainActor
    func test_asksForBothBritishAndIrishRacing() async throws {
        let provider = FakeRacingDataProvider(racecards: .success([]))
        let loader = makeLoader(provider, store: RacesStore(documents: InMemoryDocumentStore()))

        _ = try await loader.load(day: .today, now: Date())

        XCTAssertEqual(provider.lastRegionCodes, ["gb", "ire"])
    }
}
