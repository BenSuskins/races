import XCTest
@testable import RacesKit

final class RunnerMatcherTests: XCTestCase {

    private func runners(_ entries: [(String, Int?)]) -> [Runner] {
        entries.enumerated().map { index, entry in
            Runner(id: "hrs_\(index + 1)", name: entry.0, clothNumber: entry.1)
        }
    }

    private func selections(_ entries: [(String, Int?)]) -> [ExchangeRunner] {
        entries.enumerated().map { index, entry in
            ExchangeRunner(id: Int64(100 + index + 1), name: entry.0, clothNumber: entry.1)
        }
    }

    // MARK: - Cloth number first

    /// The documented primary key. Unaffected by how either side spells a name.
    func test_clothNumbersMatchDespiteDecoratedNames() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", 1), ("Stradivarius", 2)]),
            selections: selections([("1. Kyprios (IRE)", 1), ("2. Stradivarius (GB)", 2)]))

        XCTAssertEqual(result.pairings.count, 2)
        XCTAssertTrue(result.pairings.allSatisfy { $0.basis == .clothNumber })
        XCTAssertEqual(result.overlap, 1, accuracy: 0.0001)
        XCTAssertTrue(result.unmatchedHorseIDs.isEmpty)
        XCTAssertTrue(result.unmatchedSelectionIDs.isEmpty)
    }

    /// The reason the contradiction guard exists.
    ///
    /// Here the feeds disagree about numbering — cloth 1 on the exchange is the
    /// horse we have at cloth 2. Matching on the number would pair two different
    /// horses with complete confidence and price each off the other. The guard
    /// spots that the exchange's name is unambiguously our *other* runner and
    /// falls through to the name pass, which gets it right.
    func test_aContradictedClothNumberIsRefusedAndNamesWin() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", 1), ("Stradivarius", 2)]),
            selections: selections([("Stradivarius", 1), ("Kyprios", 2)]))

        let byHorse = result.pairingsByHorseID
        XCTAssertEqual(result.pairings.count, 2)
        XCTAssertTrue(result.pairings.allSatisfy { $0.basis == .exactName })
        // hrs_1 is Kyprios, which is selection 102 by name.
        XCTAssertEqual(byHorse["hrs_1"]?.selectionID, 102)
        XCTAssertEqual(byHorse["hrs_2"]?.selectionID, 101)
    }

    /// A cloth number nobody else claims is still usable even when the names
    /// differ, because a name we cannot resolve is not evidence of anything.
    func test_anUncontradictedClothNumberSurvivesANameWeCannotResolve() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", 1)]),
            selections: selections([("Unknown Runner", 1)]))

        XCTAssertEqual(result.pairings.first?.basis, RunnerPairing.Basis.clothNumber)
    }

    /// Betfair omits `CLOTH_NUMBER` on some markets. That is the whole reason a
    /// name fallback exists.
    func test_namesCarryTheJoinWhenClothNumbersAreAbsent() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", 1), ("Stradivarius", 2)]),
            selections: selections([("Kyprios (IRE)", nil), ("Stradivarius", nil)]))

        XCTAssertEqual(result.pairings.count, 2)
        XCTAssertTrue(result.pairings.allSatisfy { $0.basis == .exactName })
    }

    /// Cloth zero is Betfair's "not set", not a real saddle cloth.
    func test_clothZeroIsIgnored() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", 1)]),
            selections: selections([("Kyprios", 0)]))

        XCTAssertEqual(result.pairings.first?.basis, RunnerPairing.Basis.exactName)
    }

    /// Two selections on the same cloth number is a feed we cannot trust on that
    /// number, so it falls through rather than picking one.
    func test_aDuplicatedClothNumberIsNotUsed() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", 1)]),
            selections: selections([("Kyprios", 1), ("Someone Else", 1)]))

        XCTAssertEqual(result.pairings.first?.basis, RunnerPairing.Basis.exactName)
    }

    // MARK: - Fuzzy names, last and reluctantly

    func test_aTypoSizedDifferenceStillMatches() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", nil)]),
            selections: selections([("Kypriosa", nil)]))

        XCTAssertEqual(result.pairings.count, 1)
        XCTAssertEqual(result.pairings.first?.basis, RunnerPairing.Basis.similarName)
    }

    /// The case that would be a mismatch rather than a match. Two selections are
    /// equally close, so neither is used.
    func test_aTieOnSimilarityIsRefused() {
        let result = RunnerMatcher.match(
            runners: runners([("Misterman", nil)]),
            selections: selections([("Mistermen", nil), ("Mistermin", nil)]))

        XCTAssertTrue(result.pairings.isEmpty)
        XCTAssertEqual(result.unmatchedHorseIDs, ["hrs_1"])
    }

    /// Two of our runners both near-missing the same selection is the mirror
    /// image, and equally unsafe.
    func test_twoRunnersCompetingForOneSelectionAreBothRefused() {
        let result = RunnerMatcher.match(
            runners: runners([("Mistermen", nil), ("Mistermin", nil)]),
            selections: selections([("Misterman", nil)]))

        XCTAssertTrue(result.pairings.isEmpty)
        XCTAssertEqual(Set(result.unmatchedHorseIDs), ["hrs_1", "hrs_2"])
    }

    /// With the fuzzy pass switched off, only exact evidence counts.
    func test_strictNamesDisablesTheFuzzyPass() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", nil)]),
            selections: selections([("Kypriosa", nil)]),
            tolerances: .strictNames)

        XCTAssertTrue(result.pairings.isEmpty)
    }

    // MARK: - Partial fields

    /// A horse withdrawn on one feed and not yet the other. Ordinary, and the
    /// overlap it costs is what the threshold is measured against.
    func test_anUnmatchedRunnerIsReportedNotHidden() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", 1), ("Stradivarius", 2), ("Withdrawn One", 3)]),
            selections: selections([("Kyprios", 1), ("Stradivarius", 2)]))

        XCTAssertEqual(result.pairings.count, 2)
        XCTAssertEqual(result.unmatchedHorseIDs, ["hrs_3"])
        XCTAssertEqual(result.overlap, 2.0 / 3.0, accuracy: 0.0001)
    }

    func test_anExtraSelectionIsReportedToo() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", 1)]),
            selections: selections([("Kyprios", 1), ("Reserve Runner", 2)]))

        XCTAssertEqual(result.unmatchedSelectionIDs, [102])
        XCTAssertEqual(result.overlap, 1, accuracy: 0.0001)
    }

    func test_emptyInputsProduceNothingRatherThanCrashing() {
        let noSelections = RunnerMatcher.match(
            runners: runners([("Kyprios", 1)]), selections: [])
        XCTAssertTrue(noSelections.pairings.isEmpty)
        XCTAssertEqual(noSelections.overlap, 0, accuracy: 0.0001)

        let noRunners = RunnerMatcher.match(
            runners: [], selections: selections([("Kyprios", 1)]))
        XCTAssertTrue(noRunners.pairings.isEmpty)
        XCTAssertEqual(noRunners.overlap, 0, accuracy: 0.0001)
        XCTAssertEqual(noRunners.unmatchedSelectionIDs, [101])
    }

    // MARK: - One-to-one

    /// Whatever the passes propose, no selection may end up on two horses — that
    /// would put the same price on both.
    func test_noSelectionIsUsedTwice() {
        let result = RunnerMatcher.match(
            runners: runners([("Kyprios", 1), ("Kyprios", 2)]),
            selections: selections([("Kyprios", 1)]))

        let used = result.pairings.map(\.selectionID)
        XCTAssertEqual(used.count, Set(used).count)
        XCTAssertLessThanOrEqual(result.pairings.count, 1)
    }
}
