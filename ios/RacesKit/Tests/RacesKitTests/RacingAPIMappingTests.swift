import XCTest
@testable import RacesKit

/// Drives the mapping layer off the committed fixtures, which deliberately carry
/// the awkward shapes: numbers as strings and as numbers, blanks, nulls, missing
/// keys, and records that should be dropped entirely.
final class RacingAPIMappingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ fixture: String) throws -> T {
        try Fixture.decode(type, from: fixture, using: RacingAPIClient.decoder)
    }

    private func loadRaces() throws -> [Race] {
        let page = try decode(RacingAPIRacecardsPage.self, "racingapi-racecards-free.json")
        return (page.racecards ?? []).compactMap(RacingAPIMapping.race(from:))
    }

    private func race(_ id: String) throws -> Race {
        try XCTUnwrap(try loadRaces().first { $0.id == id })
    }

    private func runner(_ horseID: String, in raceID: String) throws -> Runner {
        try XCTUnwrap(try race(raceID).runners.first { $0.id == horseID })
    }

    // MARK: - Courses

    func test_courses_mapAndDropUnusableRecords() throws {
        let page = try decode(RacingAPICoursesPage.self, "racingapi-courses.json")
        let courses = (page.courses ?? []).compactMap(RacingAPIMapping.course(from:))

        // Seven in the fixture; one has no id and one no name, so five survive.
        XCTAssertEqual(courses.count, 5)
        XCTAssertEqual(courses.first?.name, "Ascot")
        XCTAssertTrue(courses.contains { $0.name == "Newmarket (July)" })
        XCTAssertFalse(courses.contains { $0.name.isEmpty })
        XCTAssertFalse(courses.contains { $0.id.isEmpty })
    }

    func test_courses_regionCodeIsLowercasedForComparison() throws {
        let page = try decode(RacingAPICoursesPage.self, "racingapi-courses.json")
        let courses = (page.courses ?? []).compactMap(RacingAPIMapping.course(from:))
        let leopardstown = try XCTUnwrap(courses.first { $0.name == "Leopardstown" })

        XCTAssertEqual(leopardstown.regionCode, "ire")
        XCTAssertFalse(leopardstown.isBritish)
        XCTAssertTrue(try XCTUnwrap(courses.first).isBritish)
    }

    // MARK: - Races

    /// A race with no id cannot be cached, matched to a market, or reconciled
    /// against a result, so it is dropped rather than carried as a ghost.
    func test_races_withoutAnIDAreDropped() throws {
        let races = try loadRaces()
        XCTAssertEqual(races.count, 2)
        XCTAssertFalse(races.contains { $0.courseName == "Should Be Dropped" })
    }

    func test_race_mapsRaceLevelFields() throws {
        let ascot = try race("rac_1001")

        XCTAssertEqual(ascot.courseName, "Ascot")
        XCTAssertEqual(ascot.name, "Sky Bet Handicap")
        XCTAssertEqual(ascot.going, .goodToFirm)
        XCTAssertEqual(ascot.surface, .turf)
        XCTAssertEqual(ascot.type, .flat)
        XCTAssertEqual(ascot.raceClass, 3, "'Class 3' should yield 3")
        XCTAssertEqual(ascot.distance?.furlongs, 8)
        XCTAssertEqual(ascot.distance?.displayString, "1m")
        XCTAssertEqual(ascot.ratingBand, 0...95)
        XCTAssertEqual(ascot.fieldSize, 4)
        XCTAssertEqual(ascot.prize, "£12,450")
        XCTAssertEqual(ascot.regionCode, "gb")
    }

    func test_race_emptyStringsBecomeNilNotEmptyStrings() throws {
        let ascot = try race("rac_1001")
        XCTAssertNil(ascot.pattern, "an empty pattern is absent, not a blank name")
    }

    func test_race_handicapIsInferredFromTheTitle() throws {
        XCTAssertTrue(try race("rac_1001").isHandicap)
        XCTAssertFalse(try race("rac_1002").isHandicap)
    }

    /// When `off_dt` is absent the off time has to be reconstructed from the
    /// printed time, which is 12-hour and meridiem-less.
    func test_race_offDateTimeFallsBackToThePrintedTime() throws {
        let wetherby = try race("rac_1002")
        let offDateTime = try XCTUnwrap(wetherby.offDateTime)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.timeZone = RaceDates.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        XCTAssertEqual(formatter.string(from: offDateTime), "2026-09-20 15:05")
    }

    // MARK: - Runners

    func test_runner_mapsStringEncodedNumbers() throws {
        let kyprios = try runner("hrs_1", in: "rac_1001")

        XCTAssertEqual(kyprios.name, "Kyprios")
        XCTAssertEqual(kyprios.clothNumber, 1)
        XCTAssertEqual(kyprios.draw, 3)
        XCTAssertEqual(kyprios.age, 5)
        XCTAssertEqual(kyprios.officialRating, 95)
        XCTAssertEqual(kyprios.weightPounds, 133)
        XCTAssertEqual(kyprios.daysSinceLastRun, 21)
        XCTAssertEqual(kyprios.form, "1-3241")
        XCTAssertEqual(kyprios.headgear, "b")
        XCTAssertTrue(kyprios.wearsHeadgear)
    }

    /// The same fields sent as genuine JSON numbers must map identically. The
    /// provider is not consistent, and the app must not care.
    func test_runner_mapsGenuineJSONNumbersIdentically() throws {
        let runner = try runner("hrs_4", in: "rac_1001")

        XCTAssertEqual(runner.clothNumber, 4)
        XCTAssertEqual(runner.draw, 2)
        XCTAssertEqual(runner.age, 4)
        XCTAssertEqual(runner.officialRating, 88)
        XCTAssertEqual(runner.weightPounds, 128)
        XCTAssertEqual(runner.daysSinceLastRun, 35)
    }

    /// The case that matters most. An unraced horse has no rating and no form;
    /// those must arrive as `nil`, because zero would rate it the worst horse in
    /// the race — a confident, wrong, invisible claim.
    func test_runner_unknownValuesAreNilNotZero() throws {
        let newcomer = try runner("hrs_3", in: "rac_1001")

        XCTAssertNil(newcomer.officialRating, #"ofr "" must be unknown"#)
        XCTAssertNotEqual(newcomer.officialRating, 0)
        XCTAssertNil(newcomer.daysSinceLastRun, #"last_run "-" must be unknown"#)
        XCTAssertNil(newcomer.form, "a null form must be unknown")
        XCTAssertNil(newcomer.headgear, #"headgear "" must be unknown"#)
        XCTAssertFalse(newcomer.wearsHeadgear)
    }

    func test_runner_nullHeadgearIsNil() throws {
        XCTAssertNil(try runner("hrs_2", in: "rac_1001").headgear)
    }

    /// Jumps runners have no draw — sometimes blank, sometimes the key is simply
    /// absent. Both mean the same thing.
    func test_runner_missingDrawIsNil() throws {
        XCTAssertNil(try runner("hrs_5", in: "rac_1002").draw, #"draw "" is absent"#)
        XCTAssertNil(try runner("hrs_6", in: "rac_1002").draw, "a missing draw key is absent")
    }

    func test_runner_paidTierFieldsAreNilOnTheFreePayload() throws {
        let kyprios = try runner("hrs_1", in: "rac_1001")
        XCTAssertNil(kyprios.racingPostRating)
        XCTAssertNil(kyprios.topspeedRating)
        XCTAssertNil(kyprios.spotlight)
        XCTAssertNil(kyprios.silkURL)
    }

    func test_runner_weightDisplaysInStonesAndPounds() throws {
        XCTAssertEqual(try runner("hrs_1", in: "rac_1001").weightDisplay, "9-07")
        XCTAssertEqual(try runner("hrs_5", in: "rac_1002").weightDisplay, "11-07")
    }

    func test_race_declaredRunnersAreInClothNumberOrder() throws {
        let numbers = try race("rac_1001").declaredRunners.map(\.clothNumber)
        XCTAssertEqual(numbers, [1, 2, 3, 4])
    }

    // MARK: - Results

    private func loadResults() throws -> [RaceResult] {
        let page = try decode(RacingAPIResultsPage.self, "racingapi-results-today-free.json")
        return (page.results ?? []).compactMap(RacingAPIMapping.result(from:))
    }

    func test_results_map() throws {
        let results = try loadResults()
        XCTAssertEqual(results.count, 2)

        let ascot = try XCTUnwrap(results.first { $0.id == "rac_1001" })
        XCTAssertEqual(ascot.courseName, "Ascot")
        XCTAssertEqual(ascot.going, .goodToFirm)
        XCTAssertEqual(ascot.raceClass, 3)
        XCTAssertEqual(ascot.distance?.furlongs, 8)
        XCTAssertEqual(ascot.finishers.count, 3)
    }

    func test_results_identifyTheWinner() throws {
        let ascot = try XCTUnwrap(try loadResults().first { $0.id == "rac_1001" })
        XCTAssertEqual(ascot.winner?.horseID, "hrs_2")
        XCTAssertEqual(ascot.finisher(horseID: "hrs_1")?.position, .finished(2))
    }

    func test_results_carryNonCompletions() throws {
        let wetherby = try XCTUnwrap(try loadResults().first { $0.id == "rac_1002" })

        XCTAssertEqual(wetherby.winner?.horseID, "hrs_6")
        XCTAssertEqual(wetherby.finisher(horseID: "hrs_5")?.position, .pulledUp)
        XCTAssertEqual(wetherby.finisher(horseID: "hrs_7")?.position, .fell)
    }

    /// A horse absent from a settled result was withdrawn. That is a void bet,
    /// not a losing one, and the accuracy tracker depends on the distinction.
    func test_results_didRunDistinguishesAbsenceFromDefeat() throws {
        let ascot = try XCTUnwrap(try loadResults().first { $0.id == "rac_1001" })

        XCTAssertEqual(ascot.didRun(horseID: "hrs_1"), true)
        XCTAssertEqual(ascot.didRun(horseID: "hrs_3"), false, "hrs_3 was declared but did not run")
    }

    /// A truncated payload must not settle every runner as a non-runner and
    /// quietly wipe a day of tips.
    func test_results_didRunRefusesToJudgeATinyField() {
        let sparse = RaceResult(
            id: "rac_x", courseName: "Ascot", name: "Race", date: "2026-09-20",
            finishers: [Finisher(horseID: "hrs_1", horseName: "A", position: .finished(1))]
        )
        XCTAssertNil(sparse.didRun(horseID: "hrs_9"))
    }

    // MARK: - Field helpers

    func test_raceClass_parsing() {
        XCTAssertEqual(RacingAPIMapping.raceClass(from: "Class 4"), 4)
        XCTAssertEqual(RacingAPIMapping.raceClass(from: "4"), 4)
        XCTAssertNil(RacingAPIMapping.raceClass(from: ""))
        XCTAssertNil(RacingAPIMapping.raceClass(from: "-"))
        XCTAssertNil(RacingAPIMapping.raceClass(from: nil))
        XCTAssertNil(RacingAPIMapping.raceClass(from: "Class 9"), "British racing runs 1-7")
    }

    func test_ratingBand_parsing() {
        XCTAssertEqual(RacingAPIMapping.ratingBand(from: "0-95"), 0...95)
        XCTAssertEqual(RacingAPIMapping.ratingBand(from: "76 - 95"), 76...95)
        XCTAssertNil(RacingAPIMapping.ratingBand(from: "95-76"), "an inverted band is nonsense")
        XCTAssertNil(RacingAPIMapping.ratingBand(from: "open"))
        XCTAssertNil(RacingAPIMapping.ratingBand(from: ""))
    }

    func test_nonEmpty_treatsBlanksAndDashesAsAbsent() {
        XCTAssertNil(RacingAPIMapping.nonEmpty(nil))
        XCTAssertNil(RacingAPIMapping.nonEmpty(""))
        XCTAssertNil(RacingAPIMapping.nonEmpty("   "))
        XCTAssertNil(RacingAPIMapping.nonEmpty("-"))
        XCTAssertEqual(RacingAPIMapping.nonEmpty("  Ascot "), "Ascot")
    }

    // MARK: - Meetings

    func test_racesGroupIntoMeetingsOrderedByFirstRace() throws {
        let meetings = try loadRaces().groupedIntoMeetings()

        XCTAssertEqual(meetings.count, 2)
        XCTAssertEqual(meetings.map(\.courseName), ["Ascot", "Wetherby"])
        XCTAssertEqual(meetings.first?.going, .goodToFirm)
    }
}
