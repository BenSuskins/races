import XCTest
@testable import RacesKit

final class HorseNameNormaliserTests: XCTestCase {

    // MARK: - The decoration Betfair adds

    func test_countrySuffixIsStripped() {
        XCTAssertEqual(HorseNameNormaliser.key("Kyprios (IRE)"), "KYPRIOS")
        XCTAssertEqual(HorseNameNormaliser.key("Bolshoi Ballet (FR)"), "BOLSHOIBALLET")
        XCTAssertEqual(HorseNameNormaliser.key("Yibir (USA)"), "YIBIR")
    }

    func test_clothNumberPrefixIsStripped() {
        XCTAssertEqual(HorseNameNormaliser.key("3. Kyprios"), "KYPRIOS")
        XCTAssertEqual(HorseNameNormaliser.key("12) Kyprios"), "KYPRIOS")
        XCTAssertEqual(HorseNameNormaliser.key("7 Kyprios"), "KYPRIOS")
    }

    func test_bothAtOnce() {
        XCTAssertEqual(HorseNameNormaliser.key("3. Kyprios (IRE)"), "KYPRIOS")
        XCTAssertEqual(
            HorseNameNormaliser.key("3. Kyprios (IRE)"),
            HorseNameNormaliser.key("Kyprios"))
    }

    /// The providers disagree about apostrophes — `'`, `’`, or omitted — so they
    /// come out along with every other punctuation mark.
    func test_punctuationAndSpacingDoNotMatter() {
        XCTAssertEqual(
            HorseNameNormaliser.key("O'Brien's Pride"),
            HorseNameNormaliser.key("OBriens Pride"))
        XCTAssertEqual(
            HorseNameNormaliser.key("O’Brien's Pride"),
            HorseNameNormaliser.key("O'Briens  Pride"))
        XCTAssertEqual(
            HorseNameNormaliser.key("Jack-In-The-Box"),
            HorseNameNormaliser.key("Jack In The Box"))
    }

    // MARK: - What must survive

    /// A digit that is part of the name, not a cloth number. Without the
    /// separator rule these would lose their leading numeral.
    func test_aNameThatGenuinelyStartsWithANumeralKeepsIt() {
        XCTAssertEqual(HorseNameNormaliser.key("99Problems"), "99PROBLEMS")
        XCTAssertEqual(HorseNameNormaliser.key("24Carat"), "24CARAT")
    }

    /// Only a two- or three-letter parenthetical is a country code. Anything
    /// longer is part of the name as far as we know, so it stays.
    func test_aLongerParentheticalIsNotTreatedAsACountry() {
        XCTAssertEqual(HorseNameNormaliser.key("Something (Reserve)"), "SOMETHINGRESERVE")
    }

    func test_strippingNeverEmptiesAName() {
        XCTAssertEqual(HorseNameNormaliser.key("(IRE)"), "IRE")
        XCTAssertEqual(HorseNameNormaliser.key("4."), "4")
    }

    // MARK: - Distance

    func test_identicalStringsAreZeroApart() {
        XCTAssertEqual(HorseNameNormaliser.distance("KYPRIOS", "KYPRIOS", limit: 2), 0)
    }

    func test_distanceCountsEdits() {
        XCTAssertEqual(HorseNameNormaliser.distance("KYPRIOS", "KYPRIO", limit: 2), 1)
        XCTAssertEqual(HorseNameNormaliser.distance("KYPRIOS", "KIPRIOS", limit: 2), 1)
        XCTAssertEqual(HorseNameNormaliser.distance("KYPRIOS", "KIPRIO", limit: 2), 2)
    }

    /// Beyond the limit the answer is `nil` rather than a large number — callers
    /// only ever ask "is this close enough", and the early exit is what keeps it
    /// cheap.
    func test_beyondTheLimitIsNil() {
        XCTAssertNil(HorseNameNormaliser.distance("KYPRIOS", "STRADIVARIUS", limit: 2))
        XCTAssertNil(HorseNameNormaliser.distance("ABC", "XYZ", limit: 2))
    }

    func test_lengthDifferenceAloneCanExceedTheLimit() {
        XCTAssertNil(HorseNameNormaliser.distance("AB", "ABCDE", limit: 2))
        XCTAssertEqual(HorseNameNormaliser.distance("AB", "ABCD", limit: 2), 2)
    }

    func test_emptyStrings() {
        XCTAssertEqual(HorseNameNormaliser.distance("", "", limit: 2), 0)
        XCTAssertEqual(HorseNameNormaliser.distance("", "AB", limit: 2), 2)
        XCTAssertNil(HorseNameNormaliser.distance("", "ABC", limit: 2))
    }

    /// A limit of zero means exact, which is what `MatchingTolerances.strictNames`
    /// relies on to prove a fixture matches without the fuzzy pass helping.
    func test_aLimitOfZeroAcceptsOnlyExactMatches() {
        XCTAssertEqual(HorseNameNormaliser.distance("KYPRIOS", "KYPRIOS", limit: 0), 0)
        XCTAssertNil(HorseNameNormaliser.distance("KYPRIOS", "KYPRIO", limit: 0))
    }

    /// Real pairs from the same race, to make the point that a generous limit
    /// would be dangerous rather than helpful.
    func test_genuinelySimilarNamesInOneRaceStayApart() {
        let pairs = [("MISTERMAN", "MISTERMEN"), ("SEAOFCLASS", "SEAOFGLASS")]

        for (left, right) in pairs {
            // Within two, which is exactly why the fuzzy pass refuses ties and
            // runs last rather than first.
            XCTAssertNotNil(HorseNameNormaliser.distance(left, right, limit: 2))
            XCTAssertNil(HorseNameNormaliser.distance(left, right, limit: 0))
        }
    }
}
