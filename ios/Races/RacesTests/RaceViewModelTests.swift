import XCTest
@testable import Races
import RacesKit

/// Every test is `@MainActor async`; see the gotcha in CLAUDE.md.
final class RaceViewModelTests: XCTestCase {

    private let race = Race.fixture(runners: [
        .fixture(id: "a", name: "Alpha", clothNumber: 1, officialRating: 95),
        .fixture(id: "b", name: "Bravo", clothNumber: 2, officialRating: 80),
    ])

    @MainActor
    func test_theAssessmentIsTheServers() async throws {
        let assessment = RaceRater(weights: .v2).rate(race, now: Date(timeIntervalSince1970: 0))
        let server = FakeRacesServer(race: .success(ServerRaceDetail(race: race, assessment: assessment)))
        let model = RaceViewModel(race: race, link: ServerLink(server: server))

        await model.loadIfNeeded()

        XCTAssertEqual(model.assessment, assessment)
        XCTAssertEqual(model.assessment(forHorse: "a")?.horseName, "Alpha")
    }

    @MainActor
    func test_aRefusalIsCarriedSoTheScreenCanSayWhy() async throws {
        let refusal = try RacesServerClient.decoder.decode(
            ServerRefusal.self,
            from: Data(#"{"kind":"noOverlap","displayName":"Runners don't match","marketID":"1.2","overlap":0.2}"#.utf8))
        let server = FakeRacesServer(race: .success(ServerRaceDetail(race: race, refusal: refusal)))
        let model = RaceViewModel(race: race, link: ServerLink(server: server))

        await model.loadIfNeeded()

        XCTAssertEqual(model.refusal?.displayName, "Runners don't match")
    }

    @MainActor
    func test_noServerLeavesTheCardWithoutAModelView() async {
        let model = RaceViewModel(race: race, link: ServerLink(server: nil))

        await model.loadIfNeeded()

        XCTAssertNil(model.assessment)
    }

    @MainActor
    func test_aFailureLeavesTheCardWithoutAModelView() async {
        let model = RaceViewModel(race: race, link: ServerLink(server: FakeRacesServer()))

        await model.loadIfNeeded()

        XCTAssertNil(model.assessment)
    }
}
