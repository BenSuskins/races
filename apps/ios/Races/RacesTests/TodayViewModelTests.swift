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
        _ server: FakeRacesServer?,
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> TodayViewModel {
        let link = ServerLink(server: server, unavailable: server == nil ? .notConfigured(provider: "The Races server") : nil)
        return TodayViewModel(
            loader: RacecardLoader(link: link, store: RacesStore(documents: InMemoryDocumentStore())),
            now: { now })
    }

    @MainActor
    func test_loadGroupsRacesIntoMeetingsOrderedByFirstRace() async throws {
        let model = makeModel(FakeRacesServer(racecards: [.today: .success(.fixture(races: [
            .fixture(id: "r2", courseName: "Ascot", offTime: "3:05",
                     offDateTime: Date(timeIntervalSince1970: 3_600)),
            .fixture(id: "r1", courseName: "Ascot", offTime: "2:30",
                     offDateTime: Date(timeIntervalSince1970: 1_800)),
            .fixture(id: "r3", courseName: "Ayr", offTime: "2:00",
                     offDateTime: Date(timeIntervalSince1970: 900)),
        ]))]))

        await model.load()

        let meetings = try XCTUnwrap(model.state.value)
        XCTAssertEqual(meetings.map(\.courseName), ["Ayr", "Ascot"])
        XCTAssertEqual(meetings[1].races.map(\.id), ["r1", "r2"])
    }

    @MainActor
    func test_noServerReportsNotConfiguredRatherThanFailing() async {
        let model = makeModel(nil)

        await model.load()

        guard case .failed(let error) = model.state else {
            return XCTFail("Expected a failed state, got \(model.state)")
        }
        // Not configured is information, not a fault, so `ErrorStateView`
        // must not offer a pointless retry.
        XCTAssertTrue(error.isExpectedLimitation)
    }

    @MainActor
    func test_switchingDayAsksForThatDay() async throws {
        let server = FakeRacesServer(racecards: [
            .today: .success(.fixture(races: [.fixture(id: "today")])),
            .tomorrow: .success(.fixture(day: .tomorrow, races: [.fixture(id: "tomorrow")])),
        ])
        let model = makeModel(server)
        await model.load()

        await model.select(.tomorrow)

        XCTAssertEqual(model.day, .tomorrow)
        XCTAssertEqual(try XCTUnwrap(model.state.value).first?.races.first?.id, "tomorrow")
    }

    @MainActor
    func test_aServerErrorFailsTheScreen() async {
        let model = makeModel(FakeRacesServer(racecards: [.today: .failure(.unauthorized)]))

        await model.load()

        guard case .failed(let error) = model.state else {
            return XCTFail("Expected a failed state")
        }
        XCTAssertEqual(error, .unauthorized)
        XCTAssertNil(model.staleSince)
    }
}
