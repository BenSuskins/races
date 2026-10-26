import XCTest
@testable import RacesKit

final class CourseNameNormaliserTests: XCTestCase {

    // MARK: - The pairs this exists for

    /// Each pair is the same course as the two providers spell it. The Racing API
    /// uses the official name; Betfair's `Event.venue` uses the short one.
    func test_theProvidersSpellingsAgreeAfterNormalising() {
        let pairs: [(String, String)] = [
            ("Catterick Bridge", "Catterick"),
            ("Great Yarmouth", "Yarmouth"),
            ("Epsom Downs", "Epsom"),
            ("Kempton Park", "Kempton"),
            ("Haydock Park", "Haydock"),
            ("Sandown Park", "Sandown"),
            ("Lingfield Park", "Lingfield"),
            ("Fontwell Park", "Fontwell"),
            ("Hamilton Park", "Hamilton"),
            ("Chelmsford City", "Chelmsford"),
            ("Bangor-on-Dee", "Bangor"),
            ("Stratford-on-Avon", "Stratford"),
            ("The Curragh", "Curragh"),
            ("Gowran Park", "Gowran"),
            ("Newmarket (July)", "Newmarket"),
            ("Wolverhampton (AW)", "Wolverhampton"),
            ("Dundalk (AW)", "Dundalk"),
            ("Ascot Racecourse", "Ascot"),
        ]

        for (official, exchange) in pairs {
            XCTAssertTrue(
                CourseNameNormaliser.matches(official, exchange),
                "\(official) should match \(exchange), got "
                    + "'\(CourseNameNormaliser.key(official))' vs "
                    + "'\(CourseNameNormaliser.key(exchange))'")
        }
    }

    func test_caseAndPunctuationDoNotMatter() {
        XCTAssertTrue(CourseNameNormaliser.matches("MARKET RASEN", "Market Rasen"))
        XCTAssertTrue(CourseNameNormaliser.matches("Newton  Abbot", "newton abbot"))
        XCTAssertTrue(CourseNameNormaliser.matches("Ffos Las", "FFOS LAS"))
    }

    // MARK: - The test that makes the rest safe

    /// Every British and Irish course, asserted to keep a distinct key.
    ///
    /// This is the important one. A normaliser that collapses two real courses
    /// together would let one meeting's races be priced off another's market —
    /// a silent, confident, completely wrong answer. Stripping a word is only
    /// acceptable while this passes, so any new rule has to be checked here
    /// first.
    func test_noTwoRealCoursesShareAKey() {
        var keys: [String: String] = [:]

        for course in Self.allCourses {
            let key = CourseNameNormaliser.key(course)
            XCTAssertFalse(key.isEmpty, "\(course) normalised to nothing")

            if let existing = keys[key] {
                XCTFail("\(course) and \(existing) both normalise to '\(key)'")
            }
            keys[key] = course
        }

        XCTAssertEqual(keys.count, Self.allCourses.count)
    }

    /// `Down Royal` is a course, so `royal` is not a droppable word — dropping it
    /// would leave `down`, which is neither distinct nor meaningful.
    func test_downRoyalKeepsBothWords() {
        XCTAssertEqual(CourseNameNormaliser.key("Down Royal"), "down royal")
        XCTAssertFalse(CourseNameNormaliser.matches("Down Royal", "Downpatrick"))
    }

    /// The words that identify a course are never stripped, even where they look
    /// like the droppable ones.
    func test_loadBearingWordsSurvive() {
        XCTAssertEqual(CourseNameNormaliser.key("Newton Abbot"), "newton abbot")
        XCTAssertEqual(CourseNameNormaliser.key("Market Rasen"), "market rasen")
        XCTAssertEqual(CourseNameNormaliser.key("Ffos Las"), "ffos las")
        XCTAssertEqual(CourseNameNormaliser.key("Musselburgh"), "musselburgh")
    }

    // MARK: - Newmarket, deliberately

    /// Newmarket's two tracks collapse to one key on purpose: Betfair calls both
    /// of them `Newmarket`, so the July Course and the Rowley Mile can only be
    /// told apart by start time and by which horses are in the race. That is the
    /// `RaceMatcher`'s job, not this one's.
    func test_newmarketsTwoCoursesCollapseOnPurpose() {
        XCTAssertEqual(
            CourseNameNormaliser.key("Newmarket (July)"),
            CourseNameNormaliser.key("Newmarket (Rowley Mile)"))
    }

    // MARK: - Degenerate input

    func test_emptyAndNonsenseInput() {
        XCTAssertEqual(CourseNameNormaliser.key(""), "")
        XCTAssertEqual(CourseNameNormaliser.key("   "), "")
        XCTAssertEqual(CourseNameNormaliser.key("(AW)"), "")

        // An empty key must never match, or every unnamed course would match
        // every other one.
        XCTAssertFalse(CourseNameNormaliser.matches("", ""))
        XCTAssertFalse(CourseNameNormaliser.matches("(AW)", "(July)"))
    }

    /// A name made only of droppable words keeps the last one rather than
    /// vanishing.
    func test_aNameOfNothingButDroppableWordsIsNotErased() {
        XCTAssertEqual(CourseNameNormaliser.key("Park"), "park")
        XCTAssertEqual(CourseNameNormaliser.key("The"), "the")
    }

    // MARK: - Fixtures

    private static let britishCourses = [
        "Aintree", "Ascot", "Ayr", "Bangor-on-Dee", "Bath", "Beverley", "Brighton",
        "Carlisle", "Cartmel", "Catterick Bridge", "Chelmsford City", "Cheltenham",
        "Chepstow", "Chester", "Doncaster", "Epsom Downs", "Exeter", "Fakenham",
        "Ffos Las", "Fontwell Park", "Goodwood", "Great Yarmouth", "Hamilton Park",
        "Haydock Park", "Hereford", "Hexham", "Huntingdon", "Kelso", "Kempton Park",
        "Leicester", "Lingfield Park", "Ludlow", "Market Rasen", "Musselburgh",
        "Newbury", "Newcastle", "Newmarket", "Newton Abbot", "Nottingham", "Perth",
        "Plumpton", "Pontefract", "Redcar", "Ripon", "Salisbury", "Sandown Park",
        "Sedgefield", "Southwell", "Stratford-on-Avon", "Taunton", "Thirsk",
        "Uttoxeter", "Warwick", "Wetherby", "Wincanton", "Windsor", "Wolverhampton",
        "Worcester", "York",
    ]

    private static let irishCourses = [
        "Ballinrobe", "Bellewstown", "Clonmel", "Cork", "Curragh", "Down Royal",
        "Downpatrick", "Dundalk", "Fairyhouse", "Galway", "Gowran Park",
        "Kilbeggan", "Killarney", "Laytown", "Leopardstown", "Limerick",
        "Listowel", "Naas", "Navan", "Punchestown", "Roscommon", "Sligo",
        "Thurles", "Tipperary", "Tramore", "Wexford",
    ]

    static let allCourses = britishCourses + irishCourses
}
