import XCTest
@testable import RacesKit

final class ResultsArchiveTests: XCTestCase {

    private func aRace(id: String = "rac_1") -> RaceResult {
        TestResult.result(
            id: id,
            finishing: [("hrs_1", "1"), ("hrs_2", "2"), ("hrs_3", "PU")],
            jockeys: ["hrs_1": "jky_1", "hrs_2": "jky_2", "hrs_3": "jky_1"],
            trainers: ["hrs_1": "trn_1", "hrs_2": "trn_1", "hrs_3": "trn_2"]
        )
    }

    func test_ingestingBuildsStrikeRates() throws {
        var archive = ResultsArchive()
        XCTAssertTrue(archive.ingest(aRace()))

        XCTAssertEqual(archive.jockeyStrikeRate(id: "jky_1"), StrikeRate(runs: 2, wins: 1))
        XCTAssertEqual(archive.jockeyStrikeRate(id: "jky_2"), StrikeRate(runs: 1, wins: 0))
        XCTAssertEqual(archive.trainerStrikeRate(id: "trn_1"), StrikeRate(runs: 2, wins: 1))
        XCTAssertEqual(archive.raceCount, 1)
        XCTAssertEqual(archive.totalRuns, 3)
        XCTAssertEqual(archive.totalWins, 1)
        XCTAssertEqual(archive.horseGoingRate(horseID: "hrs_1", surface: .turf, bucket: .good), HorseGoingPlaceRate(runs: 1, places: 1))
        XCTAssertEqual(archive.horseOverallPlaceRate(horseID: "hrs_1"), HorseGoingPlaceRate(runs: 1, places: 1))
    }

    func test_legacyArchiveWithoutHorseGoingDataStillDecodes() throws {
        let legacy = Data(#"{"jockeys":{},"trainers":{},"ingestedRaceIDs":[],"totalRuns":0,"totalWins":0}"#.utf8)
        let archive = try JSONDecoder().decode(ResultsArchive.self, from: legacy)
        XCTAssertTrue(archive.horseGoing.isEmpty)
    }

    func test_horseGoingFactorUsesGoingHistoryAndKeepsSmallSamplesNeutral() throws {
        var archive = ResultsArchive()
        for index in 1...3 {
            archive.ingest(TestResult.result(
                id: "soft_\(index)",
                finishing: [("horse", index == 2 ? "4" : "1"), ("other", "2"), ("third", "3")]
            ))
        }
        let race = TestRace.race(runners: [TestRace.runner("horse"), TestRace.runner("another")])
        let context = FactorContext(race: race, strikeRates: archive)
        let reading = HorseGoingFactor().value(for: race.runners[0], in: context)
        XCTAssertTrue(reading.availability.isAvailable)
        XCTAssertTrue(reading.display.contains("on similar ground from 3 runs"))
        let unknownHorse = HorseGoingFactor().value(for: TestRace.runner("unknown"), in: context)
        XCTAssertEqual(unknownHorse.raw, 0.25)
        XCTAssertEqual(unknownHorse.display, "Field place prior (25%)")
    }

    /// The single most important property of this type. The app re-fetches
    /// today's results repeatedly through an afternoon, and counting the same
    /// race twice would inflate every figure derived from it.
    func test_ingestingTheSameRaceTwiceChangesNothing() {
        var archive = ResultsArchive()
        archive.ingest(aRace())

        XCTAssertFalse(archive.ingest(aRace()), "the second ingest should be refused")

        XCTAssertEqual(archive.jockeyStrikeRate(id: "jky_1"), StrikeRate(runs: 2, wins: 1))
        XCTAssertEqual(archive.totalRuns, 3)
        XCTAssertEqual(archive.raceCount, 1)
    }

    func test_ingestingABatchCountsOnlyTheNewRaces() {
        var archive = ResultsArchive()
        archive.ingest(aRace(id: "rac_1"))

        let added = archive.ingest([aRace(id: "rac_1"), aRace(id: "rac_2"), aRace(id: "rac_3")])

        XCTAssertEqual(added, 2)
        XCTAssertEqual(archive.raceCount, 3)
    }

    /// A horse that pulled up still ran, and its jockey still had the ride.
    func test_nonCompletionsCountAsRuns() {
        var archive = ResultsArchive()
        archive.ingest(aRace())

        XCTAssertEqual(archive.jockeyStrikeRate(id: "jky_1")?.runs, 2, "including the pulled-up ride")
    }

    func test_anEmptyResultIsIgnored() {
        var archive = ResultsArchive()
        XCTAssertFalse(archive.ingest(TestResult.result(finishing: [])))
        XCTAssertEqual(archive.raceCount, 0)
    }

    func test_unknownSubjectsHaveNoRecord() {
        var archive = ResultsArchive()
        archive.ingest(aRace())

        XCTAssertNil(archive.jockeyStrikeRate(id: "jky_nobody"))
        XCTAssertNil(archive.trainerStrikeRate(id: "trn_nobody"))
    }

    // MARK: - Baseline

    /// Until there is enough archive to measure it, the baseline is a stated
    /// assumption rather than a computed figure — and it only affects how hard a
    /// thin record is pulled back toward the middle.
    func test_theBaselineFallsBackUntilThereIsEnoughHistory() {
        var archive = ResultsArchive()
        archive.ingest(aRace())

        XCTAssertEqual(archive.baselineStrikeRate, 0.125, accuracy: 0.000001)
    }

    func test_theBaselineIsMeasuredOnceThereIsEnoughHistory() {
        var archive = ResultsArchive()
        // 40 races of five runners: 200 runs, 40 winners — a 20% baseline.
        for index in 1...40 {
            archive.ingest(TestResult.result(
                id: "rac_\(index)",
                finishing: [("a", "1"), ("b", "2"), ("c", "3"), ("d", "4"), ("e", "5")],
                jockeys: ["a": "jky_a"]
            ))
        }

        XCTAssertEqual(archive.totalRuns, 200)
        XCTAssertEqual(archive.baselineStrikeRate, 0.20, accuracy: 0.000001)
    }

    // MARK: - Feeding the rater

    func test_theArchiveCanDriveTheStrikeRateFactors() throws {
        var archive = ResultsArchive()
        for index in 1...40 {
            archive.ingest(TestResult.result(
                id: "rac_\(index)",
                finishing: [("a", "1"), ("b", "2"), ("c", "3")],
                jockeys: ["a": "jky_hot", "b": "jky_cold", "c": "jky_cold"]
            ))
        }

        let race = TestRace.race(runners: [
            TestRace.runner("h1", number: 1, officialRating: 80, form: "111", jockeyID: "jky_hot"),
            TestRace.runner("h2", number: 2, officialRating: 80, form: "111", jockeyID: "jky_cold"),
        ])

        let factor = StrikeRateFactor(subject: .jockey, minimumSample: 30)
        let context = FactorContext(race: race, strikeRates: archive)

        let hot = factor.value(for: race.runners[0], in: context)
        let cold = factor.value(for: race.runners[1], in: context)

        XCTAssertTrue(hot.availability.isAvailable)
        XCTAssertTrue(cold.availability.isAvailable)
        XCTAssertGreaterThan(try XCTUnwrap(hot.raw), try XCTUnwrap(cold.raw))
    }
}
