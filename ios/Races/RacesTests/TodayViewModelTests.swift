import XCTest
@testable import Races
import RacesKit

final class TodayViewModelTests: XCTestCase {

    @MainActor
    func test_loadGroupsRacesIntoMeetingsOrderedByFirstRace() async throws {
        let provider = FakeRacingDataProvider(racecards: .success([
            .fixture(id: "r2", courseName: "Ascot", offTime: "3:05",
                     offDateTime: Date(timeIntervalSince1970: 3_600)),
            .fixture(id: "r1", courseName: "Ascot", offTime: "2:30",
                     offDateTime: Date(timeIntervalSince1970: 1_800)),
            .fixture(id: "r3", courseName: "Ayr", offTime: "2:00",
                     offDateTime: Date(timeIntervalSince1970: 900)),
        ]))
        let model = TodayViewModel(provider: provider, unavailable: nil)

        await model.load()

        let meetings = try XCTUnwrap(model.state.value)
        XCTAssertEqual(meetings.map(\.courseName), ["Ayr", "Ascot"])
        XCTAssertEqual(meetings[1].races.map(\.id), ["r1", "r2"])
    }

    @MainActor
    func test_noProviderReportsNotConfiguredRatherThanFailing() async {
        let model = TodayViewModel(
            provider: nil,
            unavailable: .notConfigured(provider: "The Racing API"))

        await model.load()

        guard case .failed(let error) = model.state else {
            return XCTFail("Expected a failed state, got \(model.state)")
        }
        // The distinction the UI keys off: an unconfigured provider is information,
        // not a fault, so `ErrorStateView` must not offer a pointless retry.
        XCTAssertTrue(error.isExpectedLimitation)
    }

    @MainActor
    func test_aBrokenKeychainOutranksAMissingKey() async {
        // `AppEnvironment` decides this; the model must simply not second-guess it.
        let model = TodayViewModel(provider: nil, unavailable: .decoding)

        await model.load()

        guard case .failed(let error) = model.state else {
            return XCTFail("Expected a failed state, got \(model.state)")
        }
        XCTAssertEqual(error, .decoding)
        XCTAssertFalse(error.isExpectedLimitation)
    }

    @MainActor
    func test_loadIfNeededSkipsARefetchWhileFresh() async {
        let provider = FakeRacingDataProvider(racecards: .success([.fixture()]))
        var now = Date(timeIntervalSince1970: 0)
        let model = TodayViewModel(provider: provider, unavailable: nil, now: { now })

        await model.loadIfNeeded()
        XCTAssertEqual(provider.racecardCalls, 1)

        now = now.addingTimeInterval(TodayViewModel.freshness - 1)
        await model.loadIfNeeded()
        XCTAssertEqual(provider.racecardCalls, 1, "Should still be inside the freshness window")

        now = now.addingTimeInterval(2)
        await model.loadIfNeeded()
        XCTAssertEqual(provider.racecardCalls, 2, "Window elapsed, so it should refetch")
    }

    @MainActor
    func test_anExplicitRefreshIgnoresTheFreshnessWindow() async {
        let provider = FakeRacingDataProvider(racecards: .success([.fixture()]))
        let now = Date(timeIntervalSince1970: 0)
        let model = TodayViewModel(provider: provider, unavailable: nil, now: { now })

        await model.load()
        await model.load()

        // Pull to refresh exists precisely for the case where the user knows
        // something has changed and the clock disagrees.
        XCTAssertEqual(provider.racecardCalls, 2)
    }

    @MainActor
    func test_aFailedLoadDoesNotCountAsFresh() async {
        let provider = FakeRacingDataProvider(racecards: .failure(.offline))
        let now = Date(timeIntervalSince1970: 0)
        let model = TodayViewModel(provider: provider, unavailable: nil, now: { now })

        await model.load()
        XCTAssertTrue(model.isStale, "A failure must not suppress the next attempt")

        await model.loadIfNeeded()
        XCTAssertEqual(provider.racecardCalls, 2)
    }

    @MainActor
    func test_anEmptyCardLoadsRatherThanErroring() async throws {
        let provider = FakeRacingDataProvider(racecards: .success([]))
        let model = TodayViewModel(provider: provider, unavailable: nil)

        await model.load()

        // A day with no British or Irish racing is a real day, not a failure.
        XCTAssertEqual(try XCTUnwrap(model.state.value).count, 0)
    }

    @MainActor
    func test_asksForBothBritishAndIrishRacing() async {
        let provider = FakeRacingDataProvider(racecards: .success([]))
        let model = TodayViewModel(provider: provider, unavailable: nil)

        await model.load()

        XCTAssertEqual(provider.lastRegionCodes, ["gb", "ire"])
    }
}
