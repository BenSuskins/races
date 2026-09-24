import XCTest
@testable import Races
import RacesKit

/// Every test is `@MainActor async`; see the gotcha in CLAUDE.md.
final class CoursesViewModelTests: XCTestCase {

    @MainActor
    private func makeModel(_ server: FakeRacesServer) -> CoursesViewModel {
        let link = ServerLink(server: server)
        return CoursesViewModel(
            link: link,
            racecards: RacecardLoader(link: link, store: RacesStore(documents: InMemoryDocumentStore())))
    }

    @MainActor
    func test_attachesTodaysRacesToTheirCourse() async throws {
        let model = makeModel(FakeRacesServer(
            racecards: [.today: .success(.fixture(races: [
                .fixture(id: "r1", courseName: "Ascot"),
                .fixture(id: "r2", courseName: "Ascot"),
            ]))],
            courses: .success([.fixture(id: "c1", name: "Ascot"), .fixture(id: "c2", name: "Ayr")])))

        await model.load()

        let listings = try XCTUnwrap(model.state.value)
        XCTAssertEqual(listings.map(\.course.name), ["Ascot", "Ayr"])
        XCTAssertEqual(listings[0].races.count, 2)
        XCTAssertFalse(listings[1].hasRacingToday)
    }

    @MainActor
    func test_matchesCourseNamesThroughTheNormaliser() async throws {
        // The card gives the course by name only, and the course list does
        // not spell it identically. Keying on the raw string would show
        // Newmarket as having no racing on a day it is the feature meeting.
        let model = makeModel(FakeRacesServer(
            racecards: [.today: .success(.fixture(races: [.fixture(id: "r1", courseName: "Newmarket (July)")]))],
            courses: .success([.fixture(id: "c1", name: "Newmarket")])))

        await model.load()

        XCTAssertTrue(try XCTUnwrap(model.state.value)[0].hasRacingToday, "Normalised names should join")
    }

    @MainActor
    func test_aFailedCardStillLeavesAUsableCourseList() async throws {
        let model = makeModel(FakeRacesServer(
            racecards: [.today: .failure(.offline)],
            courses: .success([.fixture(name: "Ascot")])))

        await model.load()

        // Degrade visibly: the list is the content, the card is the bonus.
        let listings = try XCTUnwrap(model.state.value)
        XCTAssertEqual(listings.count, 1)
        XCTAssertFalse(listings[0].hasRacingToday)
        XCTAssertEqual(model.cardUnavailable, .offline)
    }

    @MainActor
    func test_aFailedCourseListFailsTheScreen() async {
        let server = FakeRacesServer(racecards: [.today: .success(.fixture(races: []))], courses: .failure(.unauthorized))
        let model = makeModel(server)

        await model.load()

        guard case .failed(let error) = model.state else {
            return XCTFail("Expected a failed state, got \(model.state)")
        }
        XCTAssertEqual(error, .unauthorized)
        XCTAssertEqual(server.racecardCalls, 0, "No point asking for a card we cannot key")
    }
}
