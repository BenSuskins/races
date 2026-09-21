import XCTest
@testable import Races
import RacesKit

final class CoursesViewModelTests: XCTestCase {

    @MainActor
    func test_attachesTodaysRacesToTheirCourse() async throws {
        let provider = FakeRacingDataProvider(
            courses: .success([
                .fixture(id: "c1", name: "Ascot"),
                .fixture(id: "c2", name: "Ayr"),
            ]),
            racecards: .success([
                .fixture(id: "r1", courseName: "Ascot"),
                .fixture(id: "r2", courseName: "Ascot"),
            ]))
        let model = CoursesViewModel(provider: provider, unavailable: nil)

        await model.load()

        let listings = try XCTUnwrap(model.state.value)
        XCTAssertEqual(listings.map(\.course.name), ["Ascot", "Ayr"])
        XCTAssertEqual(listings[0].races.count, 2)
        XCTAssertFalse(listings[1].hasRacingToday)
    }

    @MainActor
    func test_matchesCourseNamesThroughTheNormaliser() async throws {
        // The free racecard gives the course by name only, and the two feeds do not
        // spell it identically. Keying on the raw string would show Newmarket as
        // having no racing on a day it is the feature meeting.
        let provider = FakeRacingDataProvider(
            courses: .success([.fixture(id: "c1", name: "Newmarket")]),
            racecards: .success([.fixture(id: "r1", courseName: "Newmarket (July)")]))
        let model = CoursesViewModel(provider: provider, unavailable: nil)

        await model.load()

        let listings = try XCTUnwrap(model.state.value)
        XCTAssertEqual(listings.count, 1)
        XCTAssertTrue(listings[0].hasRacingToday, "Normalised names should join")
    }

    @MainActor
    func test_aFailedCardStillLeavesAUsableCourseList() async throws {
        let provider = FakeRacingDataProvider(
            courses: .success([.fixture(name: "Ascot")]),
            racecards: .failure(.offline))
        let model = CoursesViewModel(provider: provider, unavailable: nil)

        await model.load()

        // Degrade visibly: the list is the content, the card is the bonus.
        let listings = try XCTUnwrap(model.state.value)
        XCTAssertEqual(listings.count, 1)
        XCTAssertFalse(listings[0].hasRacingToday)
        XCTAssertEqual(model.cardUnavailable, .offline)
    }

    @MainActor
    func test_aFailedCourseListFailsTheScreen() async {
        let provider = FakeRacingDataProvider(
            courses: .failure(.unauthorized),
            racecards: .success([]))
        let model = CoursesViewModel(provider: provider, unavailable: nil)

        await model.load()

        guard case .failed(let error) = model.state else {
            return XCTFail("Expected a failed state, got \(model.state)")
        }
        XCTAssertEqual(error, .unauthorized)
        XCTAssertEqual(provider.racecardCalls, 0, "No point asking for a card we cannot key")
    }

    @MainActor
    func test_aRecoveredCardClearsThePreviousNote() async {
        let failing = FakeRacingDataProvider(
            courses: .success([.fixture()]), racecards: .failure(.offline))
        let model = CoursesViewModel(provider: failing, unavailable: nil)
        await model.load()
        XCTAssertNotNil(model.cardUnavailable)

        let working = CoursesViewModel(
            provider: FakeRacingDataProvider(
                courses: .success([.fixture()]),
                racecards: .success([.fixture()])),
            unavailable: nil)
        await working.load()
        XCTAssertNil(working.cardUnavailable)
    }
}
