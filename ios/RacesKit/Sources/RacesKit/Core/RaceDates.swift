import Foundation

/// Date handling for British racing.
///
/// A racing day is a **Europe/London** day, not a UTC one. Through British Summer
/// Time the two disagree for an hour either side of midnight, which is enough to
/// put an evening meeting on the wrong date, invalidate a cache key at the wrong
/// moment, or reconcile a tip against the following day's results. So every date
/// string in the app is produced here and nowhere else.
public enum RaceDates {

    public static let timeZone = TimeZone(identifier: "Europe/London") ?? TimeZone(identifier: "UTC")!

    /// yyyy-MM-dd, the form both providers use and the form we key caches by.
    /// `en_GB_POSIX` so the format is stable regardless of the device's locale —
    /// a user with a non-Gregorian calendar would otherwise get unparseable dates.
    public static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public nonisolated(unsafe) static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static var londonCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_GB_POSIX")
        return calendar
    }

    public static func dayString(for date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    public static func dayString(for day: RaceDay, now: Date = Date()) -> String {
        switch day {
        case .today:
            return dayString(for: now)
        case .tomorrow:
            let tomorrow = londonCalendar.date(byAdding: .day, value: 1, to: now) ?? now
            return dayString(for: tomorrow)
        }
    }

    /// Which of the two days a provider can be asked for, if either.
    ///
    /// The market endpoints take a `RaceDay`, not a date, so a screen holding a
    /// single `Race` needs this to know what to ask for. `nil` means the race is
    /// outside the window both providers cover, and the correct answer there is
    /// no market rather than a guess at the nearest day.
    public static func day(matching dayString: String, now: Date = Date()) -> RaceDay? {
        if dayString == self.dayString(for: .today, now: now) { return .today }
        if dayString == self.dayString(for: .tomorrow, now: now) { return .tomorrow }
        return nil
    }

    /// Parse a provider timestamp. Both providers send ISO-8601, but not always
    /// with the same precision, and the Racing API sometimes omits the zone —
    /// in which case London is the right assumption, since these are British
    /// off times.
    public static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        if let date = iso8601.date(from: raw) { return date }
        if let date = iso8601WithFractionalSeconds.date(from: raw) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_GB_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// Combine a "yyyy-MM-dd" date with an "HH:mm" off time, in London.
    ///
    /// British racecards print afternoon times in 12-hour form without a meridiem:
    /// a 2:30 race is written "2:30" and means half past two in the afternoon.
    /// Anything before 10:00 is therefore read as PM, which covers every card bar
    /// the genuinely rare early-morning fixture.
    public static func combine(date dayString: String, offTime: String) -> Date? {
        let pieces = offTime.split(separator: ":")
        guard pieces.count >= 2,
              var hour = Int(pieces[0]),
              let minute = Int(pieces[1]),
              let day = dayFormatter.date(from: dayString) else { return nil }

        if hour < 10 { hour += 12 }

        return londonCalendar.date(
            bySettingHour: min(hour, 23),
            minute: min(minute, 59),
            second: 0,
            of: day
        )
    }
}
