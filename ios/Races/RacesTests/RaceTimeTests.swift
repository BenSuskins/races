import XCTest
@testable import Races
import RacesKit

/// Off times, read from somewhere that is not the UK.
///
/// The bug these exist for was reported from Greece: the app showed a race as
/// "13:30" because that is what the Racing API printed, on a device whose clock
/// said 15:14. The race had not run — London was 13:14 — but nothing on screen
/// said the two numbers were on different clocks, so the only reasonable reading
/// was that the app had lost two hours of results.
final class RaceTimeTests: XCTestCase {

    private static let london = RaceDates.timeZone
    private static let athens = TimeZone(identifier: "Europe/Athens")!
    private static let dublin = TimeZone(identifier: "Europe/Dublin")!
    private static let newYork = TimeZone(identifier: "America/New_York")!

    /// 2026-09-22 13:30 London (BST, so 12:30 UTC).
    private static let off = RaceDates.parseTimestamp("2026-09-22T13:30:00+01:00")!

    private func race(offDateTime: Date? = RaceTimeTests.off, offTime: String = "13:30") -> Race {
        Race(
            id: "rac_1", courseName: "Ascot", name: "A Race", offTime: offTime,
            offDateTime: offDateTime, date: "2026-09-22", runners: [])
    }

    /// Pinned, because `Locale.current` on a CI runner decides whether "13:30"
    /// comes back as "1:30 PM" — and then these assertions fail for a reason
    /// that has nothing to do with the bug they cover.
    private static let en_GB = Locale(identifier: "en_GB")

    // MARK: - Display

    func test_aUKDeviceSeesThePrintedTime() {
        let shown = RaceTime.display(
            race(), timeZone: Self.london, locale: Self.en_GB)

        XCTAssertEqual(shown, "13:30")
    }

    func test_aGreekDeviceSeesTheTimeTheRaceActuallyRunsThere() {
        // The reported case. Athens is UTC+3 in September, London UTC+1, so a
        // race printed 13:30 goes off at 15:30 local.
        let shown = RaceTime.display(
            race(), timeZone: Self.athens, locale: Self.en_GB)

        XCTAssertEqual(shown, "15:30")
    }

    func test_aNewYorkDeviceSeesTheMorning() {
        let shown = RaceTime.display(
            race(), timeZone: Self.newYork, locale: Self.en_GB)

        XCTAssertEqual(shown, "08:30")
    }

    func test_withNoParsedInstantThePrintedStringIsShown() {
        // Real, not defensive padding: a race with no `off_dt` and an
        // unparseable printed time has no instant. Showing the raw string beats
        // showing nothing — and it is exactly the case where the tip can never
        // settle, so this screen and the Record tab disagreeing is a signal.
        let shown = RaceTime.display(
            race(offDateTime: nil, offTime: "2:30"),
            timeZone: Self.athens,
            locale: Self.en_GB)

        XCTAssertEqual(shown, "2:30")
    }

    // MARK: - Whether to say anything

    func test_aUKDeviceIsNotWarned() {
        XCTAssertFalse(
            RaceTime.isAwayFromRacingTime(timeZone: Self.london, now: Self.off))
        XCTAssertNil(
            RaceTime.timeZoneNote(
                timeZone: Self.london, now: Self.off, locale: Self.en_GB))
    }

    func test_aDublinDeviceIsNotWarnedEither() {
        // Different zone, same clock all year. Comparing identifiers rather than
        // offsets would nag Dublin for nothing, which is how a useful notice
        // gets learned as noise.
        XCTAssertFalse(
            RaceTime.isAwayFromRacingTime(timeZone: Self.dublin, now: Self.off))
        XCTAssertNil(
            RaceTime.timeZoneNote(
                timeZone: Self.dublin, now: Self.off, locale: Self.en_GB))
    }

    func test_aGreekDeviceIsToldWhichClockAndByHowMuch() throws {
        XCTAssertTrue(
            RaceTime.isAwayFromRacingTime(timeZone: Self.athens, now: Self.off))

        let note = try XCTUnwrap(
            RaceTime.timeZoneNote(
                timeZone: Self.athens, now: Self.off, locale: Self.en_GB))

        // Naming the offset matters: "shown in your local time" alone leaves a
        // reader converting in their head from a base the screen never states.
        XCTAssertTrue(note.contains("2 hours ahead of"), note)
        XCTAssertTrue(note.contains("UK racing time"), note)
    }

    func test_aWesternDeviceIsToldItIsBehind() throws {
        let note = try XCTUnwrap(
            RaceTime.timeZoneNote(
                timeZone: Self.newYork, now: Self.off, locale: Self.en_GB))

        XCTAssertTrue(note.contains("5 hours behind"), note)
    }

    func test_aOneHourOffsetIsSingular() throws {
        let note = try XCTUnwrap(
            RaceTime.timeZoneNote(
                timeZone: TimeZone(identifier: "Europe/Paris")!,
                now: Self.off,
                locale: Self.en_GB))

        XCTAssertTrue(note.contains("1 hour ahead of"), note)
        XCTAssertFalse(note.contains("1 hours"), note)
    }

    // MARK: - The thing that made it confusing

    func test_theDisplayedTimeAndWhetherItHasRunNowAgree() throws {
        // The heart of the report. At 13:14 London the race has not run, and on
        // a Greek device the clock says 15:14 — which read against a bare
        // "13:30" looks like a race that finished nearly two hours ago.
        //
        // Formatting the instant instead means the screen says 15:30, and
        // "not yet run" is then obviously right rather than obviously wrong.
        let thirteenFourteenLondon = RaceDates.parseTimestamp("2026-09-22T13:14:00+01:00")!
        let halfPastOne = race()
        let off = try XCTUnwrap(halfPastOne.offDateTime)

        XCTAssertGreaterThan(off, thirteenFourteenLondon)
        XCTAssertEqual(
            RaceTime.display(halfPastOne, timeZone: Self.athens, locale: Self.en_GB),
            "15:30")
    }
}
