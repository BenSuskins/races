import XCTest
@testable import RacesKit

final class RaceMatcherTests: XCTestCase {

    private let field = ["Kyprios", "Stradivarius", "Trueshan", "Pyledriver", "Hukum"]

    // MARK: - The ordinary case

    func test_aCardMatchesItsMarkets() throws {
        let race = TestMatching.race(horses: field)
        let market = TestMatching.market(selections: field)

        let report = RaceMatcher.match(races: [race], markets: [market])
        let match = try XCTUnwrap(report.matches.first)

        XCTAssertEqual(report.matches.count, 1)
        XCTAssertEqual(match.marketID, "1.100")
        XCTAssertEqual(match.runnerOverlap, 1, accuracy: 0.0001)
        XCTAssertEqual(report.matchRate, 1, accuracy: 0.0001)
        XCTAssertTrue(report.refusals.isEmpty)
        XCTAssertTrue(report.unclaimedMarketIDs.isEmpty)
    }

    /// The providers' spellings differ and the join still lands.
    func test_courseSpellingsAreNormalisedBeforeComparison() {
        let race = TestMatching.race(course: "Catterick Bridge", horses: field)
        let market = TestMatching.market(venue: "Catterick", selections: field)

        XCTAssertEqual(RaceMatcher.match(races: [race], markets: [market]).matches.count, 1)
    }

    /// Betfair's decoration does not reach the matcher's conclusions.
    func test_decoratedSelectionNamesStillMatch() throws {
        let race = TestMatching.race(horses: ["Kyprios", "Stradivarius"])
        let market = TestMatching.market(
            selections: ["1. Kyprios (IRE)", "2. Stradivarius (GB)"])

        let report = RaceMatcher.match(races: [race], markets: [market])
        let match = try XCTUnwrap(report.matches.first)

        XCTAssertEqual(match.runnerOverlap, 1, accuracy: 0.0001)
    }

    // MARK: - The time window

    func test_aMarketInsideTheWindowMatches() {
        let race = TestMatching.race(horses: field)
        let market = TestMatching.market(startAt: TestMatching.at(5), selections: field)

        let report = RaceMatcher.match(races: [race], markets: [market])
        XCTAssertEqual(report.matches.count, 1)
        XCTAssertEqual(report.matches.first?.minutesApart ?? 0, 5, accuracy: 0.0001)
    }

    func test_aMarketOutsideTheWindowDoesNot() {
        let race = TestMatching.race(horses: field)
        let market = TestMatching.market(startAt: TestMatching.at(7), selections: field)

        let report = RaceMatcher.match(races: [race], markets: [market])
        XCTAssertEqual(report.refusals["rac_1"], MatchRefusal.noCandidate)
    }

    /// Symmetric: a market timed *earlier* than the advertised off is as normal
    /// as a later one.
    func test_theWindowWorksInBothDirections() {
        let race = TestMatching.race(horses: field)
        let market = TestMatching.market(startAt: TestMatching.at(-5), selections: field)

        XCTAssertEqual(RaceMatcher.match(races: [race], markets: [market]).matches.count, 1)
    }

    // MARK: - Where course and time are not enough

    /// Newmarket's July Course and Rowley Mile normalise to one name, so two
    /// meetings there produce markets that agree on course and can agree on time.
    /// Only the horses tell them apart — which is what the overlap check is for.
    func test_twoMeetingsAtOneCourseAreSeparatedByTheirRunners() {
        let july = TestMatching.race(
            id: "rac_july", course: "Newmarket (July)", horses: field)
        let rowley = TestMatching.race(
            id: "rac_rowley", course: "Newmarket (Rowley Mile)",
            horses: ["Baaeed", "Adayar", "Mishriff", "Alcohol Free", "Palace Pier"])

        let julyMarket = TestMatching.market(id: "1.july", selections: field)
        let rowleyMarket = TestMatching.market(
            id: "1.rowley",
            selections: ["Baaeed", "Adayar", "Mishriff", "Alcohol Free", "Palace Pier"])

        let report = RaceMatcher.match(
            races: [july, rowley], markets: [julyMarket, rowleyMarket])

        XCTAssertEqual(report.matchesByRaceID["rac_july"]?.marketID, "1.july")
        XCTAssertEqual(report.matchesByRaceID["rac_rowley"]?.marketID, "1.rowley")
        XCTAssertTrue(report.refusals.isEmpty)
    }

    /// The flaw this design exists to avoid, pinned so it cannot return.
    ///
    /// Both fields number their runners 1–5, because every race does. If the
    /// saddle-cloth pass were allowed to run while candidate markets are being
    /// scored, all five would pair on number alone, the overlap would read 100%,
    /// and a completely unrelated market would be accepted with total confidence.
    /// Cloth numbers say nothing about *which* race a field belongs to; only
    /// names do.
    func test_clothNumbersAloneCannotIdentifyARace() {
        let race = TestMatching.race(
            numbered: [("Kyprios", 1), ("Stradivarius", 2), ("Trueshan", 3),
                       ("Pyledriver", 4), ("Hukum", 5)])
        let wrongRace = TestMatching.market(
            detailed: [
                (name: "Baaeed", cloth: 1, active: true),
                (name: "Adayar", cloth: 2, active: true),
                (name: "Mishriff", cloth: 3, active: true),
                (name: "Alcohol Free", cloth: 4, active: true),
                (name: "Palace Pier", cloth: 5, active: true),
            ])

        let report = RaceMatcher.match(races: [race], markets: [wrongRace])

        XCTAssertTrue(report.matches.isEmpty)
        XCTAssertEqual(report.refusals["rac_1"], MatchRefusal.noOverlap(marketID: "1.100", overlap: 0))
    }

    /// The other half of the same rule: once the market *is* settled, cloth
    /// numbers are exactly what resolves a runner whose name the two feeds spell
    /// differently. Here four names agree — enough evidence to identify the race
    /// — and the fifth is paired on its saddle cloth.
    func test_clothNumbersFillInRunnersOnceTheMarketIsSettled() {
        let race = TestMatching.race(horses: field)
        let market = TestMatching.market(
            selections: ["Kyprios", "Stradivarius", "Trueshan", "Pyledriver",
                         "Hukum The Second"])

        let report = RaceMatcher.match(races: [race], markets: [market])
        let match = report.matches.first

        XCTAssertNotNil(match)
        // Four of five identified the race...
        XCTAssertEqual(match?.nameEvidence ?? 0, 0.8, accuracy: 0.0001)
        // ...and the cloth pass then covered the whole field.
        XCTAssertEqual(match?.runnerOverlap ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(
            match?.runners.pairingsByHorseID["hrs_rac_1_5"]?.basis, RunnerPairing.Basis.clothNumber)
    }

    /// Right course, right time, wrong horses. This is the match that would
    /// otherwise anchor every runner to another race's prices — silently, and
    /// looking entirely correct in the UI.
    func test_aMarketForADifferentRaceIsRefused() {
        let race = TestMatching.race(horses: field)
        let market = TestMatching.market(
            selections: ["Baaeed", "Adayar", "Mishriff", "Alcohol Free", "Palace Pier"])

        let report = RaceMatcher.match(races: [race], markets: [market])

        XCTAssertTrue(report.matches.isEmpty)
        XCTAssertEqual(report.refusals["rac_1"], MatchRefusal.noOverlap(marketID: "1.100", overlap: 0))
        XCTAssertEqual(report.unclaimedMarketIDs, ["1.100"])
    }

    /// Just under the threshold. Three of five is 0.6 and passes; two of five is
    /// 0.4 and does not.
    func test_theOverlapThresholdIsApplied() {
        let race = TestMatching.race(horses: field)

        let justEnough = TestMatching.market(
            selections: ["Kyprios", "Stradivarius", "Trueshan", "Stranger", "Another"])
        XCTAssertEqual(
            RaceMatcher.match(races: [race], markets: [justEnough]).matches.count, 1)

        let notEnough = TestMatching.market(
            selections: ["Kyprios", "Stradivarius", "Stranger", "Another", "AndAnother"])
        let report = RaceMatcher.match(races: [race], markets: [notEnough])
        XCTAssertTrue(report.matches.isEmpty)
        if case .noOverlap(_, let overlap)? = report.refusals["rac_1"] {
            XCTAssertEqual(overlap, 0.4, accuracy: 0.0001)
        } else {
            XCTFail("expected a noOverlap refusal, got \(String(describing: report.refusals["rac_1"]))")
        }
    }

    /// Nothing separates the two markets: same course, same time, same field. A
    /// coin toss here would be a 50% chance of pricing the race off the wrong
    /// market, so it refuses.
    func test_anUnbreakableTieIsRefused() {
        let race = TestMatching.race(horses: field)
        let first = TestMatching.market(id: "1.a", selections: field)
        let second = TestMatching.market(id: "1.b", selections: field)

        let report = RaceMatcher.match(races: [race], markets: [first, second])

        XCTAssertTrue(report.matches.isEmpty)
        XCTAssertEqual(report.refusals["rac_1"], MatchRefusal.ambiguous(marketIDs: ["1.a", "1.b"]))
    }

    /// A tie on the field is broken by the clock, which is a real signal even if
    /// it is the weaker one.
    func test_aTieOnRunnersIsBrokenByTime() {
        let race = TestMatching.race(horses: field)
        let near = TestMatching.market(
            id: "1.near", startAt: TestMatching.at(1), selections: field)
        let far = TestMatching.market(
            id: "1.far", startAt: TestMatching.at(5), selections: field)

        let report = RaceMatcher.match(races: [race], markets: [near, far])

        XCTAssertEqual(report.matches.first?.marketID, "1.near")
        XCTAssertEqual(report.unclaimedMarketIDs, ["1.far"])
    }

    /// Overlap beats proximity. A market three minutes away with the right horses
    /// is the race; one at the exact minute with the wrong horses is not.
    func test_runnersOutrankTheClock() {
        let race = TestMatching.race(horses: field)
        let exactButWrong = TestMatching.market(
            id: "1.wrong", startAt: TestMatching.at(0),
            selections: ["Baaeed", "Adayar", "Mishriff", "Alcohol Free", "Palace Pier"])
        let laterButRight = TestMatching.market(
            id: "1.right", startAt: TestMatching.at(3), selections: field)

        let report = RaceMatcher.match(
            races: [race], markets: [exactButWrong, laterButRight])

        XCTAssertEqual(report.matches.first?.marketID, "1.right")
    }

    // MARK: - Removed runners

    /// A removed selection is excluded rather than counted as a miss. Otherwise a
    /// race that matched perfectly would lose its market to withdrawals.
    func test_removedSelectionsDoNotCountAgainstTheOverlap() throws {
        let race = TestMatching.race(horses: ["Kyprios", "Stradivarius"])
        let market = TestMatching.market(
            detailed: [
                (name: "Kyprios", cloth: 1, active: true),
                (name: "Stradivarius", cloth: 2, active: true),
                (name: "Withdrawn", cloth: 3, active: false),
            ])

        let report = RaceMatcher.match(races: [race], markets: [market])
        let match = try XCTUnwrap(report.matches.first)

        XCTAssertEqual(match.runnerOverlap, 1, accuracy: 0.0001)
        XCTAssertTrue(match.runners.unmatchedSelectionIDs.isEmpty)
    }

    // MARK: - Nothing to match on

    func test_aRaceWithNoOffTimeIsRefusedWithItsReason() {
        let race = TestMatching.race(offAt: nil, horses: field)
        let market = TestMatching.market(selections: field)

        XCTAssertEqual(
            RaceMatcher.match(races: [race], markets: [market]).refusals["rac_1"],
            MatchRefusal.noOffTime)
    }

    func test_aRaceWithNoRunnersIsRefusedWithItsReason() {
        let race = TestMatching.race(horses: [])
        let market = TestMatching.market(selections: field)

        XCTAssertEqual(
            RaceMatcher.match(races: [race], markets: [market]).refusals["rac_1"],
            MatchRefusal.noRunners)
    }

    func test_aCourseWithNoMarketsAtAll() {
        let race = TestMatching.race(course: "Perth", horses: field)
        let market = TestMatching.market(venue: "Newmarket", selections: field)

        let report = RaceMatcher.match(races: [race], markets: [market])
        XCTAssertEqual(report.refusals["rac_1"], MatchRefusal.noCandidate)
        XCTAssertEqual(report.unclaimedMarketIDs, ["1.100"])
    }

    func test_emptyInputs() {
        let empty = RaceMatcher.match(races: [], markets: [])
        XCTAssertTrue(empty.matches.isEmpty)
        XCTAssertTrue(empty.refusals.isEmpty)
        XCTAssertEqual(empty.matchRate, 0, accuracy: 0.0001)
    }

    // MARK: - One market, one race

    /// Two races cannot share a market. Whichever is matched first takes it, and
    /// the other is refused rather than given a duplicate.
    func test_aMarketIsClaimedOnce() {
        let bigger = TestMatching.race(id: "rac_big", horses: field)
        let smaller = TestMatching.race(
            id: "rac_small", horses: ["Kyprios", "Stradivarius", "Trueshan"])
        let market = TestMatching.market(selections: field)

        let report = RaceMatcher.match(races: [bigger, smaller], markets: [market])

        XCTAssertEqual(report.matches.count, 1)
        XCTAssertEqual(report.matches.first?.raceID, "rac_big")
        XCTAssertNotNil(report.refusals["rac_small"])
        XCTAssertEqual(report.matchRate, 0.5, accuracy: 0.0001)
    }

    // MARK: - Provenance

    /// A match that leaned on the fuzzy pass says so, because that is the pass
    /// most likely to be wrong and the UI may want to be quieter about it.
    func test_aMatchRecordsWhetherItNeededSimilarNames() {
        let clean = RaceMatcher.match(
            races: [TestMatching.race(horses: field)],
            markets: [TestMatching.market(selections: field)])
        XCTAssertEqual(clean.matches.first?.usedSimilarNames, false)

        let unnumberedField: [(String, Int?)] = field.map { ($0, nil) }
        let unnumberedSelections: [(name: String, cloth: Int?, active: Bool)] =
            (["Kypriosa"] + field.dropFirst()).map {
                (name: $0, cloth: nil, active: true)
            }

        let fuzzy = RaceMatcher.match(
            races: [TestMatching.race(numbered: unnumberedField)],
            markets: [TestMatching.market(detailed: unnumberedSelections)])
        XCTAssertEqual(fuzzy.matches.first?.usedSimilarNames, true)
    }

    func test_pairingsAreReachableByHorseID() {
        let race = TestMatching.race(horses: field)
        let market = TestMatching.market(selections: field)

        let report = RaceMatcher.match(races: [race], markets: [market])
        let pairings = report.matches.first?.runners.pairingsByHorseID ?? [:]

        XCTAssertEqual(pairings.count, field.count)
        XCTAssertNotNil(pairings["hrs_rac_1_1"])
    }
}
