import XCTest
@testable import Races
import RacesKit

/// Every test here is `@MainActor async`, and the `async` is load-bearing even
/// where nothing is awaited: a synchronous `@MainActor` test method never runs its
/// body, reports `failed` in 0.000s with no message, and stops the rest of the
/// suite from reporting at all. See the gotcha in CLAUDE.md.
final class TodayViewModelTests: XCTestCase {

    @MainActor
    private func makeModel(
        _ provider: FakeRacingDataProvider?,
        unavailable: APIError? = nil,
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> TodayViewModel {
        let store = RacesStore(documents: InMemoryDocumentStore())
        return TodayViewModel(
            loader: RacecardLoader(provider: provider, store: store),
            unavailable: unavailable,
            now: { now })
    }

    @MainActor
    func test_loadGroupsRacesIntoMeetingsOrderedByFirstRace() async throws {
        let model = makeModel(FakeRacingDataProvider(racecards: .success([
            .fixture(id: "r2", courseName: "Ascot", offTime: "3:05",
                     offDateTime: Date(timeIntervalSince1970: 3_600)),
            .fixture(id: "r1", courseName: "Ascot", offTime: "2:30",
                     offDateTime: Date(timeIntervalSince1970: 1_800)),
            .fixture(id: "r3", courseName: "Ayr", offTime: "2:00",
                     offDateTime: Date(timeIntervalSince1970: 900)),
        ])))

        await model.load()

        let meetings = try XCTUnwrap(model.state.value)
        XCTAssertEqual(meetings.map(\.courseName), ["Ayr", "Ascot"])
        XCTAssertEqual(meetings[1].races.map(\.id), ["r1", "r2"])
    }

    @MainActor
    func test_noProviderReportsNotConfiguredRatherThanFailing() async {
        let model = makeModel(nil)

        await model.load()

        guard case .failed(let error) = model.state else {
            return XCTFail("Expected a failed state, got \(model.state)")
        }
        // An unconfigured provider is information, not a fault, so
        // `ErrorStateView` must not offer a pointless retry.
        XCTAssertTrue(error.isExpectedLimitation)
    }

    @MainActor
    func test_aBrokenKeychainShortCircuitsBeforeTheLoader() async {
        // A missing key does not short-circuit: the cache may still hold a card.
        // A broken Keychain does, because nothing downstream can be trusted.
        let provider = FakeRacingDataProvider(racecards: .success([.fixture()]))
        let model = makeModel(provider, unavailable: .decoding)

        await model.load()

        guard case .failed(let error) = model.state else {
            return XCTFail("Expected a failed state, got \(model.state)")
        }
        XCTAssertEqual(error, .decoding)
        XCTAssertEqual(provider.racecardCalls, 0)
    }

    @MainActor
    func test_loadIfNeededDoesNotRefetchOnceLoaded() async {
        let provider = FakeRacingDataProvider(racecards: .success([.fixture()]))
        let model = makeModel(provider)

        await model.loadIfNeeded()
        await model.loadIfNeeded()

        XCTAssertEqual(provider.racecardCalls, 1)
    }

    @MainActor
    func test_anEmptyCardLoadsRatherThanErroring() async throws {
        let model = makeModel(FakeRacingDataProvider(racecards: .success([])))

        await model.load()

        // A day with no British or Irish racing is a real day, not a failure.
        let meetings = try XCTUnwrap(model.state.value)
        XCTAssertEqual(meetings.count, 0)
    }

    @MainActor
    func test_switchingDayReloads() async {
        let provider = FakeRacingDataProvider(racecards: .success([.fixture()]))
        let model = makeModel(provider)

        await model.loadIfNeeded()
        XCTAssertEqual(model.day, .today)

        await model.select(.tomorrow)

        XCTAssertEqual(model.day, .tomorrow)
        XCTAssertEqual(provider.racecardCalls, 2, "Tomorrow is a different card")
    }

    @MainActor
    func test_selectingTheSameDayIsANoOp() async {
        let provider = FakeRacingDataProvider(racecards: .success([.fixture()]))
        let model = makeModel(provider)
        await model.loadIfNeeded()

        await model.select(.today)

        XCTAssertEqual(provider.racecardCalls, 1)
    }

    @MainActor
    func test_aStaleCardIsFlaggedSoTheScreenCanSayWhenItWasSaved() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        let start = Date(timeIntervalSince1970: 1_000_000)

        let working = RacecardLoader(
            provider: FakeRacingDataProvider(racecards: .success([.fixture()])), store: store)
        _ = try? await working.load(day: .today, now: start)

        let later = start.addingTimeInterval(StoreDocument.racecardFreshness + 1)
        let model = TodayViewModel(
            loader: RacecardLoader(
                provider: FakeRacingDataProvider(racecards: .failure(.offline)), store: store),
            unavailable: nil,
            now: { later })

        await model.load()

        XCTAssertNotNil(model.state.value, "A stale card still loads")
        XCTAssertEqual(model.staleSince?.timeIntervalSince1970 ?? 0, start.timeIntervalSince1970, accuracy: 1)
    }

    @MainActor
    func test_aFreshCardClearsTheStaleFlag() async {
        let provider = FakeRacingDataProvider(racecards: .success([.fixture()]))
        let model = makeModel(provider)

        await model.load()

        XCTAssertNil(model.staleSince)
    }
}
