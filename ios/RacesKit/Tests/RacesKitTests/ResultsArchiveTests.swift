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

    func test_legacyArchiveWithoutSurfaceRatesStillDecodes() throws {
        let legacy = Data(#"{"jockeys":{},"trainers":{},"ingestedRaceIDs":[],"totalRuns":0,"totalWins":0}"#.utf8)
        let archive = try JSONDecoder().decode(ResultsArchive.self, from: legacy)
        XCTAssertTrue(archive.jockeySurfaces.isEmpty)
        XCTAssertTrue(archive.trainerSurfaces.isEmpty)
        XCTAssertTrue(archive.jockeyRaceTypes.isEmpty)
        XCTAssertTrue(archive.trainerRaceTypes.isEmpty)
        XCTAssertTrue(archive.jockeyGoings.isEmpty)
        XCTAssertTrue(archive.trainerGoings.isEmpty)
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

    func test_archiveTracksJockeyAndTrainerRatesBySurface() {
        var archive = ResultsArchive()
        archive.ingest(TestResult.result(
            id: "turf",
            finishing: [("a", "1"), ("b", "2")],
            jockeys: ["a": "jockey", "b": "jockey"],
            trainers: ["a": "trainer", "b": "trainer"]
        ))
        XCTAssertEqual(archive.jockeySurfaceStrikeRate(id: "jockey", surface: .turf), StrikeRate(runs: 2, wins: 1))
        XCTAssertEqual(archive.trainerSurfaceStrikeRate(id: "trainer", surface: .turf), StrikeRate(runs: 2, wins: 1))
        XCTAssertNil(archive.jockeySurfaceStrikeRate(id: "jockey", surface: .allWeather))
    }

    func test_surfaceStrikeRateRequiresThirtyRunsAndShrinksToTheGeneralRecord() throws {
        var archive = ResultsArchive()
        for index in 1...30 {
            let first = index <= 10 ? "1" : "2"
            archive.ingest(TestResult.result(
                id: "surface_\(index)",
                finishing: [("a", first), ("b", index <= 10 ? "2" : "1")],
                jockeys: ["a": "hot"],
                trainers: ["a": "stable"]
            ))
        }
        let race = TestRace.race(surface: .turf, runners: [
            TestRace.runner("a", jockeyID: "hot", trainerID: "stable"),
            TestRace.runner("b"),
        ])
        let context = FactorContext(race: race, strikeRates: archive)
        let jockey = SurfaceStrikeRateFactor(subject: .jockey).value(for: race.runners[0], in: context)
        let trainer = SurfaceStrikeRateFactor(subject: .trainer).value(for: race.runners[0], in: context)
        XCTAssertTrue(jockey.availability.isAvailable)
        XCTAssertEqual(jockey.raw, trainer.raw)
        XCTAssertTrue(jockey.display.contains("from 30 turf runs"))

        let allWeather = TestRace.race(surface: .allWeather, runners: race.runners)
        let missing = SurfaceStrikeRateFactor(subject: .jockey).value(
            for: allWeather.runners[0],
            in: FactorContext(race: allWeather, strikeRates: archive)
        )
        XCTAssertEqual(missing.availability, .missingData("no record in this surface archive yet"))
    }

    func test_raceTypeArchiveSeparatesFlatAndJumpsAndRequiresThirtyRuns() {
        var archive = ResultsArchive()
        for index in 1...30 {
            archive.ingest(TestResult.result(
                id: "flat_\(index)",
                finishing: [("a", index <= 10 ? "1" : "2"), ("b", index <= 10 ? "2" : "1")],
                jockeys: ["a": "hot"],
                trainers: ["a": "stable"]
            ))
        }
        archive.ingest(TestResult.result(
            id: "hurdle_1",
            finishing: [("a", "1"), ("b", "2")],
            jockeys: ["a": "hot"], trainers: ["a": "stable"], type: .hurdle
        ))
        XCTAssertEqual(archive.jockeyRaceTypeStrikeRate(id: "hot", raceType: .flat), StrikeRate(runs: 30, wins: 10))
        XCTAssertEqual(archive.trainerRaceTypeStrikeRate(id: "stable", raceType: .flat), StrikeRate(runs: 30, wins: 10))
        XCTAssertEqual(archive.jockeyRaceTypeStrikeRate(id: "hot", raceType: .hurdle), StrikeRate(runs: 1, wins: 1))

        let race = TestRace.race(type: .flat, runners: [
            TestRace.runner("a", jockeyID: "hot", trainerID: "stable"), TestRace.runner("b")
        ])
        let context = FactorContext(race: race, strikeRates: archive)
        let reading = RaceTypeStrikeRateFactor(subject: .jockey).value(for: race.runners[0], in: context)
        XCTAssertTrue(reading.availability.isAvailable)
        XCTAssertEqual(reading.raw ?? 0, 0.30588235294117644, accuracy: 0.000001)

        let hurdleRace = TestRace.race(type: .hurdle, runners: race.runners)
        let missing = RaceTypeStrikeRateFactor(subject: .jockey).value(
            for: hurdleRace.runners[0], in: FactorContext(race: hurdleRace, strikeRates: archive)
        )
        XCTAssertEqual(missing.availability, .missingData("only 1 runs in this race type"))
        let unknownRace = TestRace.race(type: .unknown, runners: race.runners)
        let unknown = RaceTypeStrikeRateFactor(subject: .jockey).value(
            for: unknownRace.runners[0], in: FactorContext(race: unknownRace, strikeRates: archive)
        )
        XCTAssertEqual(unknown.availability, .missingData("race type is unknown"))
    }

    func test_goingArchiveSeparatesBucketsAndRequiresThirtyRuns() {
        var archive = ResultsArchive()
        for index in 1...30 {
            archive.ingest(TestResult.result(
                id: "good_\(index)",
                finishing: [("a", index <= 10 ? "1" : "2"), ("b", index <= 10 ? "2" : "1")],
                jockeys: ["a": "hot"], trainers: ["a": "stable"]
            ))
        }
        archive.ingest(TestResult.result(
            id: "soft_1", finishing: [("a", "1"), ("b", "2")],
            jockeys: ["a": "hot"], trainers: ["a": "stable"], going: .soft
        ))
        XCTAssertEqual(archive.jockeyGoingStrikeRate(id: "hot", surface: .turf, bucket: .good), StrikeRate(runs: 30, wins: 10))
        XCTAssertEqual(archive.trainerGoingStrikeRate(id: "stable", surface: .turf, bucket: .good), StrikeRate(runs: 30, wins: 10))
        XCTAssertEqual(archive.jockeyGoingStrikeRate(id: "hot", surface: .turf, bucket: .soft), StrikeRate(runs: 1, wins: 1))

        let race = TestRace.race(going: .good, runners: [
            TestRace.runner("a", jockeyID: "hot", trainerID: "stable"), TestRace.runner("b")
        ])
        let reading = GoingStrikeRateFactor(subject: .jockey).value(
            for: race.runners[0], in: FactorContext(race: race, strikeRates: archive)
        )
        XCTAssertTrue(reading.availability.isAvailable)
        XCTAssertEqual(reading.raw ?? 0, 0.30588235294117644, accuracy: 0.000001)

        let unknown = TestRace.race(going: .unknown, runners: race.runners)
        let missing = GoingStrikeRateFactor(subject: .jockey).value(
            for: unknown.runners[0], in: FactorContext(race: unknown, strikeRates: archive)
        )
        XCTAssertEqual(missing.availability, .missingData("going or surface is unknown"))
    }

    func test_recentArchiveKeepsTheLatestFiftyDatedRunsAndAppliesTheThirtyRunFloor() throws {
        var archive = ResultsArchive()
        for index in stride(from: 51, through: 1, by: -1) {
            let month = (index - 1) / 28 + 1
            let day = (index - 1) % 28 + 1
            let date = String(format: "2026-%02d-%02d", month, day)
            let winner = index <= 30
            archive.ingest(TestResult.result(
                id: String(format: "race-%02d", index), date: date,
                finishing: [("a", winner ? "1" : "2"), ("b", winner ? "2" : "1")],
                jockeys: ["a": "hot"], trainers: ["a": "stable"]
            ))
        }
        XCTAssertEqual(archive.jockeyRecentStrikeRate(id: "hot"), StrikeRate(runs: 50, wins: 29))
        XCTAssertEqual(archive.trainerRecentStrikeRate(id: "stable"), StrikeRate(runs: 50, wins: 29))
        archive.ingest(TestResult.result(id: "undated", date: "2026-02-30", finishing: [("a", "1")], jockeys: ["a": "hot"]))
        XCTAssertEqual(archive.jockeyRecentStrikeRate(id: "hot"), StrikeRate(runs: 50, wins: 29))

        let encoded = try JSONEncoder().encode(archive)
        let restored = try JSONDecoder().decode(ResultsArchive.self, from: encoded)
        XCTAssertEqual(restored.jockeyRecentStrikeRate(id: "hot"), StrikeRate(runs: 50, wins: 29))
        XCTAssertEqual(restored.trainerRecentStrikeRate(id: "stable"), StrikeRate(runs: 50, wins: 29))

        let race = TestRace.race(runners: [TestRace.runner("a", jockeyID: "hot", trainerID: "stable")])
        let context = FactorContext(race: race, strikeRates: restored)
        let jockey = RecentStrikeRateFactor(subject: .jockey).value(for: race.runners[0], in: context)
        let trainer = RecentStrikeRateFactor(subject: .trainer).value(for: race.runners[0], in: context)
        XCTAssertTrue(jockey.availability.isAvailable)
        XCTAssertTrue(trainer.availability.isAvailable)
        XCTAssertTrue(jockey.display.contains("from 50 recent runs"))

        var thin = ResultsArchive()
        for index in 1...29 {
            thin.ingest(TestResult.result(id: "thin-\(index)", finishing: [("a", "1")], jockeys: ["a": "hot"]))
        }
        let missing = RecentStrikeRateFactor(subject: .jockey).value(
            for: race.runners[0], in: FactorContext(race: race, strikeRates: thin)
        )
        XCTAssertEqual(missing.availability, .missingData("only 29 dated runs in the recent window"))
    }

    func test_jockeyTrainerArchiveAndFactorRequireMatureRecords() {
        var archive = ResultsArchive()
        for index in 1...30 {
            archive.ingest(TestResult.result(
                id: "pair-\(index)",
                finishing: [("a", index <= 12 ? "1" : "2"), ("b", index <= 12 ? "2" : "1")],
                jockeys: ["a": "jockey"], trainers: ["a": "trainer"]
            ))
        }
        XCTAssertEqual(archive.jockeyTrainerStrikeRate(jockeyID: "jockey", trainerID: "trainer"), StrikeRate(runs: 30, wins: 12))

        let race = TestRace.race(runners: [TestRace.runner("a", jockeyID: "jockey", trainerID: "trainer")])
        let reading = JockeyTrainerStrikeRateFactor().value(
            for: race.runners[0], in: FactorContext(race: race, strikeRates: archive)
        )
        XCTAssertTrue(reading.availability.isAvailable)
        XCTAssertEqual(reading.raw ?? 0, 0.356, accuracy: 0.000001)
        XCTAssertTrue(reading.display.contains("from 30 runs together"))

        var thin = ResultsArchive()
        for index in 1...29 {
            thin.ingest(TestResult.result(
                id: "thin-pair-\(index)", finishing: [("a", "1")],
                jockeys: ["a": "jockey"], trainers: ["a": "trainer"]
            ))
        }
        let missing = JockeyTrainerStrikeRateFactor().value(
            for: race.runners[0], in: FactorContext(race: race, strikeRates: thin)
        )
        XCTAssertEqual(missing.availability, .missingData("only 29 runs for this jockey-trainer pair"))
    }

    func test_drawBiasArchiveMeasuresBroadCellsAndRequiresOneHundredComparableStarts() throws {
        var archive = ResultsArchive()
        for raceIndex in 1...100 {
            let winnerDraw = raceIndex <= 60 ? 2 : 12
            let finishers = (1...12).map { draw in (String(draw), draw == winnerDraw ? "1" : "2") }
            archive.ingest(TestResult.result(
                id: "draw-race-\(raceIndex)", courseName: "Ascot", distance: Distance(exactFurlongs: 5),
                finishing: finishers, draws: Dictionary(uniqueKeysWithValues: (1...12).map { (String($0), $0) })
            ))
        }
        let race = TestRace.race(
            distance: Distance(exactFurlongs: 5), fieldSize: 12,
            runners: [TestRace.runner("2", draw: 2)]
        )
        let runner = race.runners[0]
        let record = try XCTUnwrap(archive.drawBiasRate(race: race, runner: runner))
        XCTAssertEqual(record.runs, 400)
        XCTAssertEqual(record.wins, 60)
        XCTAssertEqual(record.expectedWins, 100.0 / 3.0, accuracy: 0.000001)
        let reading = DrawFactor().value(for: runner, in: FactorContext(race: race, strikeRates: archive))
        XCTAssertTrue(reading.availability.isAvailable)
        XCTAssertEqual(reading.raw ?? 0, 0.14682539682539683, accuracy: 0.000001)

        var thinArchive = ResultsArchive()
        for raceIndex in 1...24 {
            let finishers = (1...12).map { (String($0), $0 == 2 ? "1" : "2") }
            thinArchive.ingest(TestResult.result(
                id: "thin-draw-\(raceIndex)", distance: Distance(exactFurlongs: 5),
                finishing: finishers, draws: Dictionary(uniqueKeysWithValues: (1...12).map { (String($0), $0) })
            ))
        }
        let thin = DrawFactor().value(for: runner, in: FactorContext(race: race, strikeRates: thinArchive))
        XCTAssertEqual(thin.availability, .missingData("only 96 comparable starters for this draw"))
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
