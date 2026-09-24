import XCTest
@testable import Races
import RacesKit

/// Every test is `@MainActor async`; see the gotcha in CLAUDE.md.
final class RacecardLoaderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @MainActor
    private func makeLoader(_ server: FakeRacesServer?, store: RacesStore) -> RacecardLoader {
        RacecardLoader(
            link: ServerLink(server: server, unavailable: server == nil ? .notConfigured(provider: "The Races server") : nil),
            store: store)
    }

    @MainActor
    func test_aFreshCardIsServedFromMemoryWithoutASecondRequest() async throws {
        let server = FakeRacesServer(racecards: [.today: .success(.fixture(races: [.fixture()]))])
        let loader = makeLoader(server, store: RacesStore(documents: InMemoryDocumentStore()))

        _ = try await loader.load(day: .today, now: now)
        let second = try await loader.load(day: .today, now: now.addingTimeInterval(30))

        XCTAssertEqual(server.racecardCalls, 1, "Racing and Tips share one request")
        XCTAssertTrue(second.isFresh)
    }

    @MainActor
    func test_forceRefreshAlwaysAsks() async throws {
        let server = FakeRacesServer(racecards: [.today: .success(.fixture(races: [.fixture()]))])
        let loader = makeLoader(server, store: RacesStore(documents: InMemoryDocumentStore()))

        _ = try await loader.load(day: .today, now: now)
        _ = try await loader.load(day: .today, forceRefresh: true, now: now)

        XCTAssertEqual(server.racecardCalls, 2)
    }

    /// Off the tailnet, the phone still opens on the last card it saw — and
    /// says that is what it is.
    @MainActor
    func test_anUnreachableServerFallsBackToTheSavedCard() async throws {
        let documents = InMemoryDocumentStore()
        let store = RacesStore(documents: documents)
        let saved = Date(timeIntervalSince1970: 999_000)
        let server = FakeRacesServer(racecards: [.today: .success(.fixture(races: [.fixture()], fetchedAt: saved))])
        _ = try await makeLoader(server, store: store).load(day: .today, now: now)

        server.setRacecard(.failure(.offline))
        let load = try await makeLoader(server, store: store).load(day: .today, forceRefresh: true, now: now)

        XCTAssertTrue(load.servedStaleAfterFailure)
        XCTAssertEqual(load.races.map(\.id), ["rac_1"])
        XCTAssertEqual(load.fetchedAt, saved)
    }

    @MainActor
    func test_noServerAndNoCacheIsNotConfigured() async {
        let loader = makeLoader(nil, store: RacesStore(documents: InMemoryDocumentStore()))
        do {
            _ = try await loader.load(day: .today, now: now)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(APIError.from(error).isExpectedLimitation)
        }
    }
}
