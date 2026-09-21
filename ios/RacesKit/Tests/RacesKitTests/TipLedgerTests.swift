import XCTest
@testable import RacesKit

/// The sealing rule is what makes the whole tracker mean anything, so it gets
/// the most careful tests in the package.
final class TipLedgerTests: XCTestCase {

    private let off = Date(timeIntervalSince1970: 1_800_000_000)

    private func race(offAt: Date?) -> Race {
        Race(
            id: "rac_1", courseName: "Ascot", name: "Test Handicap",
            offTime: "14:30", offDateTime: offAt, date: "2026-09-20",
            runners: [
                TestRace.runner("hrs_1", number: 1, officialRating: 90, form: "111"),
                TestRace.runner("hrs_2", number: 2, officialRating: 80, form: "222"),
            ]
        )
    }

    private func assessment(for race: Race) -> RaceAssessment {
        RaceRater().rate(race)
    }

    // MARK: - Drafting

    func test_aTipWellBeforeTheOffIsADraft() throws {
        var ledger = TipLedger()
        let race = race(offAt: off)

        let outcome = ledger.record(assessment(for: race), race: race, now: off.addingTimeInterval(-3600))

        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(ledger.count, 1)
        XCTAssertFalse(try XCTUnwrap(ledger.tip(forRace: "rac_1")).isSealed)
    }

    /// Prices move and non-runners are declared through the day, so until the
    /// race is close the latest view is the useful one.
    func test_aDraftIsOverwrittenByALaterRecompute() {
        var ledger = TipLedger()
        let race = race(offAt: off)

        ledger.record(assessment(for: race), race: race, now: off.addingTimeInterval(-7200))
        let second = ledger.record(assessment(for: race), race: race, now: off.addingTimeInterval(-3600))

        XCTAssertEqual(second, .updated)
        XCTAssertEqual(ledger.count, 1)
    }

    // MARK: - Sealing

    func test_theFirstWriteInsideTheWindowSealsTheTip() throws {
        var ledger = TipLedger()
        let race = race(offAt: off)
        let justInside = off.addingTimeInterval(-TipLedger.sealWindow + 1)

        let outcome = ledger.record(assessment(for: race), race: race, now: justInside)

        XCTAssertEqual(outcome, .sealed)
        let tip = try XCTUnwrap(ledger.tip(forRace: "rac_1"))
        XCTAssertTrue(tip.isSealed)
        XCTAssertEqual(tip.sealedAt, justInside)
    }

    func test_writesJustOutsideTheWindowDoNotSeal() {
        var ledger = TipLedger()
        let race = race(offAt: off)
        let justOutside = off.addingTimeInterval(-TipLedger.sealWindow - 1)

        XCTAssertEqual(ledger.record(assessment(for: race), race: race, now: justOutside), .created)
        XCTAssertEqual(ledger.tip(forRace: "rac_1")?.isSealed, false)
    }

    func test_aSealedTipIsNeverOverwritten() throws {
        var ledger = TipLedger()
        let race = race(offAt: off)

        ledger.record(assessment(for: race), race: race, now: off.addingTimeInterval(-60))
        let sealedAt = try XCTUnwrap(ledger.tip(forRace: "rac_1")?.sealedAt)

        let second = ledger.record(assessment(for: race), race: race, now: off.addingTimeInterval(-30))

        XCTAssertEqual(second, .rejectedAlreadySealed)
        XCTAssertEqual(ledger.tip(forRace: "rac_1")?.sealedAt, sealedAt, "the seal time must not move")
    }

    /// The rule that stops the tracker being worthless: a race first opened after
    /// it has run never enters the record at all. Otherwise it would measure what
    /// the model thought once the result was already known.
    func test_aRaceThatHasAlreadyRunIsNeverRecorded() {
        var ledger = TipLedger()
        let race = race(offAt: off)

        let outcome = ledger.record(assessment(for: race), race: race, now: off.addingTimeInterval(1))

        XCTAssertEqual(outcome, .rejectedRaceStarted)
        XCTAssertEqual(ledger.count, 0)
        XCTAssertFalse(outcome.didStore)
    }

    func test_aDraftIsNotUpdatedOnceTheRaceHasRun() {
        var ledger = TipLedger()
        let race = race(offAt: off)

        ledger.record(assessment(for: race), race: race, now: off.addingTimeInterval(-3600))
        let after = ledger.record(assessment(for: race), race: race, now: off.addingTimeInterval(60))

        XCTAssertEqual(after, .rejectedRaceStarted)
    }

    /// Conservative on purpose: better a slightly stale tip than an open door to
    /// recording one after the result is known.
    func test_aRaceWithNoKnownOffTimeIsSealedImmediately() {
        var ledger = TipLedger()
        let race = race(offAt: nil)

        let outcome = ledger.record(assessment(for: race), race: race, now: off)

        XCTAssertEqual(outcome, .sealed)
        XCTAssertEqual(ledger.tip(forRace: "rac_1")?.isSealed, true)
    }

    func test_aRaceWithNoRunnersIsNotRecorded() {
        var ledger = TipLedger()
        let empty = Race(
            id: "rac_empty", courseName: "Ascot", name: "Empty",
            offTime: "14:30", offDateTime: off, date: "2026-09-20", runners: []
        )

        let outcome = ledger.record(RaceRater().rate(empty), race: empty, now: off.addingTimeInterval(-3600))

        XCTAssertEqual(outcome, .rejectedNoSelection)
        XCTAssertEqual(ledger.count, 0)
    }

    // MARK: - Settling

    func test_settlingAnUnknownRaceIsANoOp() {
        var ledger = TipLedger()
        XCTAssertFalse(ledger.settle(raceID: "nope", outcome: .won(betfairSP: 4.0)))
    }

    func test_settlingRecordsTheOutcomeAndTheFavourite() throws {
        var ledger = TipLedger(tips: [.make()])

        let applied = ledger.settle(
            raceID: "rac_1",
            outcome: .won(betfairSP: 4.0),
            favourite: FavouriteOutcome(horseID: "hrs_1", won: true, betfairSP: 4.0)
        )

        XCTAssertTrue(applied)
        let tip = try XCTUnwrap(ledger.tip(forRace: "rac_1"))
        XCTAssertEqual(tip.outcome, .won(betfairSP: 4.0))
        XCTAssertEqual(tip.favouriteOutcome?.won, true)
    }

    /// A settled race does not un-settle. Re-running a reconcile must not be able
    /// to rewrite history.
    func test_aSettledTipIsNotResettled() throws {
        var ledger = TipLedger(tips: [.make(outcome: .won(betfairSP: 4.0))])

        XCTAssertFalse(ledger.settle(raceID: "rac_1", outcome: .lost(position: 5, betfairSP: 4.0)))
        XCTAssertEqual(ledger.tip(forRace: "rac_1")?.outcome, .won(betfairSP: 4.0))
    }

    func test_aVoidTipIsNotResettledEither() {
        var ledger = TipLedger(tips: [.make(outcome: .nonRunner)])
        XCTAssertFalse(ledger.settle(raceID: "rac_1", outcome: .won(betfairSP: 4.0)))
    }

    /// An unresolved tip is still being chased, so it may be revised.
    func test_anUnresolvedTipCanStillBeSettled() {
        var ledger = TipLedger(tips: [
            .make(outcome: .unresolved(lastCheckedAt: Date(timeIntervalSince1970: 1), attempts: 2)),
        ])

        XCTAssertTrue(ledger.settle(raceID: "rac_1", outcome: .won(betfairSP: 4.0)))
    }

    // MARK: - Queries

    func test_awaitingReconciliationFindsRunButUnsettledRaces() {
        let ledger = TipLedger(tips: [
            .make(raceID: "run_pending", offAt: off.addingTimeInterval(-3600)),
            .make(raceID: "run_unresolved", offAt: off.addingTimeInterval(-3600),
                  outcome: .unresolved(lastCheckedAt: off, attempts: 1)),
            .make(raceID: "run_settled", offAt: off.addingTimeInterval(-3600),
                  outcome: .won(betfairSP: 4.0)),
            .make(raceID: "not_yet_run", offAt: off.addingTimeInterval(3600)),
        ])

        let waiting = Set(ledger.awaitingReconciliation(now: off).map(\.raceID))

        XCTAssertEqual(waiting, ["run_pending", "run_unresolved"])
    }

    func test_ledgerRoundTripsThroughJSON() throws {
        let ledger = TipLedger(tips: [.make(), .make(raceID: "rac_2", selection: "hrs_9")])

        let data = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(TipLedger.self, from: data)

        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.tip(forRace: "rac_2")?.selectionHorseID, "hrs_9")
    }
}
