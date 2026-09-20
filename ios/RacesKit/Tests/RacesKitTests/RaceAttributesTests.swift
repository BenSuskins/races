import XCTest
@testable import RacesKit

final class RaceAttributesTests: XCTestCase {

    // MARK: - Going

    func test_going_parsesProviderStrings() {
        let cases: [(String, Going)] = [
            ("Good", .good), ("good", .good), ("GD", .good),
            ("Good To Soft", .goodToSoft), ("good to soft", .goodToSoft), ("Gd-Sft", .goodToSoft),
            ("Good To Firm", .goodToFirm),
            ("Soft", .soft), ("Heavy", .heavy), ("Firm", .firm),
            ("Standard", .standard), ("Standard To Slow", .standardToSlow),
            ("Standard To Fast", .standardToFast), ("Fast", .fast), ("Slow", .slow),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(Going(raw: raw), expected, raw)
        }
    }

    /// A going description we have not seen must not cost us the racecard.
    func test_going_unknownStringsDegradeGracefully() {
        XCTAssertEqual(Going(raw: nil), .unknown)
        XCTAssertEqual(Going(raw: ""), .unknown)
        XCTAssertEqual(Going(raw: "Yielding to Soft"), .unknown)
    }

    func test_going_identifiesAllWeatherVocabulary() {
        XCTAssertTrue(Going.standard.isAllWeather)
        XCTAssertTrue(Going.fast.isAllWeather)
        XCTAssertFalse(Going.good.isAllWeather)
        XCTAssertFalse(Going.heavy.isAllWeather)
    }

    func test_going_firmnessRankOrdersSoftToFirm() throws {
        let heavy = try XCTUnwrap(Going.heavy.firmnessRank)
        let soft = try XCTUnwrap(Going.soft.firmnessRank)
        let good = try XCTUnwrap(Going.good.firmnessRank)
        let firm = try XCTUnwrap(Going.firm.firmnessRank)

        XCTAssertLessThan(heavy, soft)
        XCTAssertLessThan(soft, good)
        XCTAssertLessThan(good, firm)
        XCTAssertNil(Going.unknown.firmnessRank)
    }

    // MARK: - Surface

    func test_surface() {
        XCTAssertEqual(Surface(raw: "Turf"), .turf)
        XCTAssertEqual(Surface(raw: "AW"), .allWeather)
        XCTAssertEqual(Surface(raw: "All Weather"), .allWeather)
        XCTAssertEqual(Surface(raw: "Polytrack"), .allWeather)
        XCTAssertEqual(Surface(raw: "Tapeta"), .allWeather)
        XCTAssertEqual(Surface(raw: nil), .unknown)
        XCTAssertEqual(Surface(raw: "Moon dust"), .unknown)
    }

    // MARK: - RaceType

    func test_raceType() {
        XCTAssertEqual(RaceType(raw: "Flat"), .flat)
        XCTAssertEqual(RaceType(raw: "Hurdle"), .hurdle)
        XCTAssertEqual(RaceType(raw: "Chase"), .chase)
        XCTAssertEqual(RaceType(raw: "NH Flat"), .nationalHuntFlat)
        XCTAssertEqual(RaceType(raw: "Bumper"), .nationalHuntFlat)
        XCTAssertEqual(RaceType(raw: nil), .unknown)
    }

    /// Completion rate is a real signal over obstacles and close to meaningless on
    /// the Flat, so the factor set keys off this.
    func test_raceType_isJumpsOnlyForObstacles() {
        XCTAssertTrue(RaceType.hurdle.isJumps)
        XCTAssertTrue(RaceType.chase.isJumps)
        XCTAssertFalse(RaceType.flat.isJumps)
        XCTAssertFalse(RaceType.nationalHuntFlat.isJumps, "a bumper has no obstacles")
        XCTAssertFalse(RaceType.unknown.isJumps)
    }

    // MARK: - Distance

    func test_distance_displaysAsMilesAndFurlongs() {
        XCTAssertEqual(Distance(exactFurlongs: 5).displayString, "5f")
        XCTAssertEqual(Distance(exactFurlongs: 8).displayString, "1m")
        XCTAssertEqual(Distance(exactFurlongs: 10).displayString, "1m 2f")
        XCTAssertEqual(Distance(exactFurlongs: 16).displayString, "2m")
        XCTAssertEqual(Distance(exactFurlongs: 20).displayString, "2m 4f")
        XCTAssertEqual(Distance(exactFurlongs: 32).displayString, "4m")
    }

    func test_distance_displaysHalfFurlongs() {
        XCTAssertEqual(Distance(exactFurlongs: 5.5).displayString, "5½f")
        XCTAssertEqual(Distance(exactFurlongs: 8.5).displayString, "1m ½f")
    }

    func test_distance_rejectsNonsense() {
        XCTAssertNil(Distance(furlongs: nil))
        XCTAssertNil(Distance(furlongs: 0))
        XCTAssertNil(Distance(furlongs: -5))
        XCTAssertNil(Distance(furlongs: .nan))
    }

    func test_distance_sprintThreshold() {
        XCTAssertTrue(Distance(exactFurlongs: 5).isSprint)
        XCTAssertTrue(Distance(exactFurlongs: 6).isSprint)
        XCTAssertFalse(Distance(exactFurlongs: 7).isSprint)
    }

    func test_distance_isComparable() {
        XCTAssertLessThan(Distance(exactFurlongs: 5), Distance(exactFurlongs: 8))
    }

    // MARK: - FinishPosition

    func test_finishPosition_parsesNumbers() {
        XCTAssertEqual(FinishPosition(raw: "1"), .finished(1))
        XCTAssertEqual(FinishPosition(raw: "12"), .finished(12))
        XCTAssertTrue(FinishPosition(raw: "1").isWinner)
        XCTAssertFalse(FinishPosition(raw: "2").isWinner)
    }

    /// Over jumps these are routine, and settling a tip needs to tell "beaten into
    /// fourth" from "never completed".
    func test_finishPosition_parsesNonCompletions() {
        XCTAssertEqual(FinishPosition(raw: "PU"), .pulledUp)
        XCTAssertEqual(FinishPosition(raw: "pu"), .pulledUp)
        XCTAssertEqual(FinishPosition(raw: "F"), .fell)
        XCTAssertEqual(FinishPosition(raw: "UR"), .unseatedRider)
        XCTAssertEqual(FinishPosition(raw: "BD"), .broughtDown)
        XCTAssertEqual(FinishPosition(raw: "DSQ"), .disqualified)

        XCTAssertFalse(FinishPosition(raw: "PU").didComplete)
        XCTAssertNil(FinishPosition(raw: "PU").numericPosition)
        XCTAssertFalse(FinishPosition(raw: "PU").isWinner)
    }

    func test_finishPosition_keepsUnknownCodesVerbatim() {
        XCTAssertEqual(FinishPosition(raw: "WTF"), .other("WTF"))
        XCTAssertEqual(FinishPosition(raw: "WTF").displayString, "WTF")
    }
}
