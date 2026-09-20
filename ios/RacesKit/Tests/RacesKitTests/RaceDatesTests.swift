import XCTest
@testable import RacesKit

final class RaceDatesTests: XCTestCase {

    private func londonTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.timeZone = RaceDates.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    func test_timeZoneIsLondon() {
        XCTAssertEqual(RaceDates.timeZone.identifier, "Europe/London")
    }

    // MARK: - Day boundaries

    /// A racing day is a London day. During British Summer Time a UTC-based
    /// `startOfDay` is an hour out, which is enough to file an evening meeting
    /// under the wrong date and reconcile its tips against the next day's results.
    func test_dayString_usesLondonNotUTC() throws {
        // 2026-07-15 23:30 UTC is 2026-07-16 00:30 in London (BST, UTC+1).
        let formatter = ISO8601DateFormatter()
        let instant = try XCTUnwrap(formatter.date(from: "2026-07-15T23:30:00Z"))

        XCTAssertEqual(RaceDates.dayString(for: instant), "2026-07-16")
    }

    func test_dayString_forRaceDay() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-09-20T12:00:00Z"))

        XCTAssertEqual(RaceDates.dayString(for: .today, now: now), "2026-09-20")
        XCTAssertEqual(RaceDates.dayString(for: .tomorrow, now: now), "2026-09-21")
    }

    func test_dayString_tomorrowCrossesMonthEnd() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-09-30T12:00:00Z"))
        XCTAssertEqual(RaceDates.dayString(for: .tomorrow, now: now), "2026-10-01")
    }

    // MARK: - Timestamps

    func test_parseTimestamp_handlesProviderFormats() {
        XCTAssertNotNil(RaceDates.parseTimestamp("2026-09-20T14:30:00+01:00"))
        XCTAssertNotNil(RaceDates.parseTimestamp("2026-09-20T14:30:00Z"))
        XCTAssertNotNil(RaceDates.parseTimestamp("2026-09-20T14:30:00.123Z"))
        XCTAssertNotNil(RaceDates.parseTimestamp("2026-09-20 14:30:00"))
        XCTAssertNotNil(RaceDates.parseTimestamp("2026-09-20T14:30:00"))
    }

    func test_parseTimestamp_rejectsRubbish() {
        XCTAssertNil(RaceDates.parseTimestamp(nil))
        XCTAssertNil(RaceDates.parseTimestamp(""))
        XCTAssertNil(RaceDates.parseTimestamp("half past two"))
    }

    func test_parseTimestamp_respectsOffset() throws {
        let date = try XCTUnwrap(RaceDates.parseTimestamp("2026-09-20T14:30:00+01:00"))
        XCTAssertEqual(londonTime(date), "2026-09-20 14:30")
    }

    // MARK: - Combining a printed off time

    /// British racecards print afternoon off times in 12-hour form with no
    /// meridiem: a 2:30 race means half past two in the afternoon. Reading that
    /// literally would put every card on the wrong side of noon.
    func test_combine_readsAfternoonTimesAsPM() throws {
        let date = try XCTUnwrap(RaceDates.combine(date: "2026-09-20", offTime: "3:05"))
        XCTAssertEqual(londonTime(date), "2026-09-20 15:05")

        let evening = try XCTUnwrap(RaceDates.combine(date: "2026-09-20", offTime: "6:30"))
        XCTAssertEqual(londonTime(evening), "2026-09-20 18:30")
    }

    func test_combine_leaves24HourTimesAlone() throws {
        let date = try XCTUnwrap(RaceDates.combine(date: "2026-09-20", offTime: "14:30"))
        XCTAssertEqual(londonTime(date), "2026-09-20 14:30")
    }

    func test_combine_rejectsMalformedInput() {
        XCTAssertNil(RaceDates.combine(date: "2026-09-20", offTime: "nonsense"))
        XCTAssertNil(RaceDates.combine(date: "2026-09-20", offTime: "1430"))
        XCTAssertNil(RaceDates.combine(date: "not-a-date", offTime: "14:30"))
    }
}
