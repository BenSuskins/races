import XCTest
@testable import Races
import RacesKit

/// `RacesStore` is an actor, so every value is read with an explicit `await` into
/// a local first. `XCTAssertEqual(await store.tips.count, 1)` does not compile:
/// the assertion takes a non-async autoclosure, and an `await` inside one is an
/// error. Hoisting is the fix, and it reads better anyway.
final class RacesStoreTests: XCTestCase {

    private func makeRace(
        id: String = "rac_1",
        offDateTime: Date? = nil,
        runners: [Runner] = [.fixture(id: "a", officialRating: 100),
                             .fixture(id: "b", officialRating: 60)]
    ) -> Race {
        Race(
            id: id, courseName: "Ascot", name: "A Race", offTime: "2:30",
            offDateTime: offDateTime, date: "2026-06-16", runners: runners)
    }

    // MARK: - Persistence

    func test_aTipSurvivesARestart() async {
        let documents = InMemoryDocumentStore()
        let race = makeRace()

        let first = RacesStore(documents: documents)
        await first.loadIfNeeded()
        await first.assessAndRecord([race])
        let firstCount = await first.tips.count
        XCTAssertEqual(firstCount, 1)

        // A second store over the same documents is what a relaunch looks like.
        let second = RacesStore(documents: documents)
        await second.loadIfNeeded()
        let secondTips = await second.tips
        XCTAssertEqual(secondTips.count, 1)
        XCTAssertEqual(secondTips.first?.raceID, race.id)
    }

    func test_anArchiveSurvivesARestart() async {
        let documents = InMemoryDocumentStore()
        let result = RaceResult.fixture(finishers: [
            .fixture(horseID: "a", position: 1),
            .fixture(horseID: "b", position: 2),
        ])

        let first = RacesStore(documents: documents)
        await first.loadIfNeeded()
        await first.ingest(results: [result])
        let firstCount = await first.archivedRaceCount
        XCTAssertEqual(firstCount, 1)

        let second = RacesStore(documents: documents)
        await second.loadIfNeeded()
        let secondCount = await second.archivedRaceCount
        XCTAssertEqual(secondCount, 1)
    }

    func test_anEmptyStoreIsNotAnError() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()

        let tips = await store.tips
        let archived = await store.archivedRaceCount
        let hasArchive = await store.hasArchive

        XCTAssertEqual(tips.count, 0)
        XCTAssertEqual(archived, 0)
        XCTAssertFalse(hasArchive)
    }

    func test_anUnreadableDocumentReadsAsEmptyRatherThanFailing() async {
        let documents = InMemoryDocumentStore()
        // A file written by a future build. Losing one file's history is bad;
        // being unable to open the app because of it is worse.
        await documents.plantRawDocument(#"{"schemaVersion":99,"savedAt":"x"}"#, as: "tips.json")

        let store = RacesStore(documents: documents)
        await store.loadIfNeeded()

        let tips = await store.tips
        XCTAssertEqual(tips.count, 0)
    }

    // MARK: - Ingestion

    func test_ingestingTheSameResultTwiceCountsItOnce() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()
        let result = RaceResult.fixture(finishers: [.fixture(horseID: "a", position: 1)])

        let first = await store.ingest(results: [result])
        let second = await store.ingest(results: [result])
        let archived = await store.archivedRaceCount

        // This runs repeatedly through an afternoon. Double-counting would
        // inflate every strike rate derived from the archive.
        XCTAssertEqual(first.newRacesArchived, 1)
        XCTAssertEqual(second.newRacesArchived, 0)
        XCTAssertEqual(archived, 1)
    }

    func test_resultsSettleAMatchingTip() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()

        let offAt = Date(timeIntervalSince1970: 10_000)
        let race = makeRace(offDateTime: offAt)

        // Recorded before the off, settled after it.
        await store.assessAndRecord([race], now: offAt.addingTimeInterval(-3_600))
        let recorded = await store.tip(forRace: "rac_1")
        let tip = try XCTUnwrap(recorded)
        XCTAssertNil(tip.outcome)

        let result = RaceResult.settleable(id: "rac_1", winner: tip.selectionHorseID)
        let ingestion = await store.ingest(
            results: [result], now: offAt.addingTimeInterval(600))
        let settledRecord = await store.tip(forRace: "rac_1")
        let settled = try XCTUnwrap(settledRecord)

        XCTAssertEqual(ingestion.tipsSettled, 1)
        XCTAssertEqual(settled.outcome?.isWin, true)
    }

    func test_aSettledTipIsNotResettledByALaterPass() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()
        let offAt = Date(timeIntervalSince1970: 10_000)

        await store.assessAndRecord(
            [makeRace(offDateTime: offAt)], now: offAt.addingTimeInterval(-3_600))
        let recorded = await store.tip(forRace: "rac_1")
        let tip = try XCTUnwrap(recorded)

        let won = RaceResult.settleable(id: "rac_1", winner: tip.selectionHorseID)
        await store.ingest(results: [won], now: offAt.addingTimeInterval(600))

        // A contradictory later payload must not rewrite history.
        let lost = RaceResult.settleableLoss(id: "rac_1", loser: tip.selectionHorseID)
        let second = await store.ingest(results: [lost], now: offAt.addingTimeInterval(1_200))
        let finalRecord = await store.tip(forRace: "rac_1")
        let final = try XCTUnwrap(finalRecord)

        XCTAssertEqual(second.tipsSettled, 0)
        XCTAssertEqual(final.outcome?.isWin, true)
    }

    // MARK: - Recording rules

    func test_aRaceThatHasAlreadyRunIsNotRecorded() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()
        let offAt = Date(timeIntervalSince1970: 10_000)

        // The sealing rule: a race first seen after it ran is never recorded,
        // or the tracker would be measuring hindsight.
        await store.assessAndRecord(
            [makeRace(offDateTime: offAt)], now: offAt.addingTimeInterval(60))

        let tips = await store.tips
        XCTAssertEqual(tips.count, 0)
    }

    // MARK: - Markets

    func test_aSuppliedMarketAnchorsTheAssessment() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()
        let race = makeRace()
        let market = MarketSnapshot(
            marketID: "1.234",
            prices: ["a": RunnerPrice(backPrice: 1.5), "b": RunnerPrice(backPrice: 4.0)])

        let assessment = await store.assess(race, market: market)

        XCTAssertFalse(assessment.isFormOnly)
        XCTAssertEqual(assessment.marketSource, .liveExchange)
        XCTAssertNotNil(assessment.runners.first?.marketProbability)
    }

    func test_aCardIsRatedRacebyRaceSoAPartialMarketIsNormal() async {
        // Some races match and some do not. A card is not all-or-nothing, and a
        // store that demanded a market for every race would drop the tips it
        // could have given.
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()
        let priced = makeRace(id: "priced")
        let unpriced = makeRace(id: "unpriced")

        let assessments = await store.assessAndRecord(
            [priced, unpriced],
            markets: [
                "priced": MarketSnapshot(
                    marketID: "1.234",
                    prices: ["a": RunnerPrice(backPrice: 1.5),
                             "b": RunnerPrice(backPrice: 4.0)])
            ])

        XCTAssertEqual(assessments["priced"]?.isFormOnly, false)
        XCTAssertEqual(assessments["unpriced"]?.isFormOnly, true)
        let tips = await store.tips
        XCTAssertEqual(tips.count, 2)
    }

    func test_withNoArchiveTheStrikeRateFactorsReportMissingNotZero() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()

        let assessment = await store.assess(makeRace())
        let runner = try XCTUnwrap(assessment.runners.first)
        let jockeyFactor = runner.contributions.first {
            $0.label.localizedCaseInsensitiveContains("jockey")
        }

        // Treating an absent record as zero would libel every runner whose
        // jockey we have simply never seen.
        XCTAssertEqual(try XCTUnwrap(jockeyFactor).availability.isAvailable, false)
    }

    func test_theArchiveAccumulatesAcrossIngests() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()

        let results = (1...30).map { index in
            RaceResult.fixture(id: "rac_\(index)", finishers: [
                .fixture(horseID: "h\(index)", position: index.isMultiple(of: 3) ? 1 : 4),
            ])
        }
        await store.ingest(results: results)

        let hasArchive = await store.hasArchive
        let count = await store.archivedRaceCount
        XCTAssertTrue(hasArchive)
        XCTAssertEqual(count, 30)
    }

    // MARK: - Racecard cache

    func test_racecardsRoundTripThroughTheCache() async throws {
        let store = RacesStore(documents: InMemoryDocumentStore())
        let races = [Race.fixture(id: "r1"), Race.fixture(id: "r2")]
        let fetchedAt = Date(timeIntervalSince1970: 500)

        await store.saveRacecards(races, day: "2026-06-16", fetchedAt: fetchedAt)
        let stored = await store.cachedRacecards(day: "2026-06-16")
        let cached = try XCTUnwrap(stored)

        XCTAssertEqual(cached.races.map(\.id), ["r1", "r2"])
        XCTAssertEqual(cached.fetchedAt.timeIntervalSince1970, 500, accuracy: 1)
    }

    func test_eachDayIsCachedSeparately() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.saveRacecards([.fixture(id: "today")], day: "2026-06-16")
        await store.saveRacecards([.fixture(id: "tomorrow")], day: "2026-06-17")

        let today = await store.cachedRacecards(day: "2026-06-16")
        let tomorrow = await store.cachedRacecards(day: "2026-06-17")
        XCTAssertEqual(today?.races.first?.id, "today")
        XCTAssertEqual(tomorrow?.races.first?.id, "tomorrow")
    }

    // MARK: - Clearing

    func test_clearingHistoryEmptiesBothDocuments() async {
        let store = RacesStore(documents: InMemoryDocumentStore())
        await store.loadIfNeeded()
        await store.assessAndRecord([makeRace()])
        await store.ingest(results: [.fixture(finishers: [.fixture(horseID: "a", position: 1)])])

        await store.clearHistory()

        let tips = await store.tips
        let archived = await store.archivedRaceCount
        XCTAssertEqual(tips.count, 0)
        XCTAssertEqual(archived, 0)
    }
}
