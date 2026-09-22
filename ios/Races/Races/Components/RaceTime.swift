import Foundation
import RacesKit

/// Off times, shown in the timezone the person is actually standing in.
///
/// The Racing API prints a **UK** local time — "13:30" — and until now the app
/// showed that string verbatim everywhere. On a device in the UK that is right
/// and free. On a device anywhere else it is silently two or three hours wrong,
/// and nothing on screen says so: a card read in Greece shows a race as half an
/// hour away when it is two and a half, and a race the app correctly treats as
/// still to come reads as one that finished ages ago. That is not a cosmetic
/// problem, because the number it contradicts is the one the whole Record tab is
/// built on.
///
/// `Race.offDateTime` is already a real instant — `RacingAPIMapping` builds it
/// from `off_dt`, or from the date and the printed time interpreted in London.
/// So the fix is only ever to format *that* rather than echo the string.
///
/// `nonisolated` because the app target defaults to MainActor isolation and this
/// is pure — it is called from view bodies and compared in nonisolated tests.
nonisolated enum RaceTime {

    /// The timezone racecards are printed in, and the only one the raw
    /// `offTime` string is correct for.
    static let racingTimeZone = RaceDates.timeZone

    /// What to put where the off time goes.
    ///
    /// Falls back to the provider's printed string when there is no parsed
    /// instant. That fallback is a real case rather than defensive padding: a
    /// race with no `off_dt` and an unparseable printed time has no instant, and
    /// showing the raw string beats showing nothing. It is also exactly the case
    /// where the tip can never settle, which is worth remembering if this screen
    /// and the Record tab ever disagree.
    static func display(
        _ race: Race,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        guard let offDateTime = race.offDateTime else { return race.offTime }

        // `Date.FormatStyle` rather than a `DateFormatter`: this is called once
        // per row per render, and allocating a `DateFormatter` in a list body is
        // the standard way to make a card scroll badly.
        //
        // Both are set as properties. `.locale(_:)` would also work, but
        // `.timeZone(_:)` is *not* its counterpart — it is the field modifier
        // that appends a zone symbol to a custom format, and it takes a
        // `Date.FormatStyle.Symbol.TimeZone`. See the gotcha in CLAUDE.md.
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return offDateTime.formatted(style)
    }

    /// Whether the device is somewhere that makes the printed UK time misleading.
    ///
    /// Compares the **current offset**, not the identifier: Europe/Dublin is a
    /// different zone from Europe/London and keeps the same clock all year, so a
    /// Dublin device needs no warning. Comparing identifiers would nag them for
    /// nothing, which is how a useful notice gets learned as noise.
    static func isAwayFromRacingTime(
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> Bool {
        timeZone.secondsFromGMT(for: now) != racingTimeZone.secondsFromGMT(for: now)
    }

    /// One line explaining what the times on this screen are, shown only where it
    /// is actually needed.
    ///
    /// Names the racing time as well as the local one. "Shown in your local time"
    /// alone would leave a reader converting in their head from a base the screen
    /// never states.
    static func timeZoneNote(
        timeZone: TimeZone = .current,
        now: Date = Date(),
        locale: Locale = .current
    ) -> String? {
        guard isAwayFromRacingTime(timeZone: timeZone, now: now) else { return nil }

        let localName = timeZone.localizedName(for: .shortGeneric, locale: locale)
            ?? timeZone.identifier
        let difference = timeZone.secondsFromGMT(for: now)
            - racingTimeZone.secondsFromGMT(for: now)
        let hours = abs(difference) / 3600
        let direction = difference > 0 ? "ahead of" : "behind"
        let plural = hours == 1 ? "hour" : "hours"

        return "Times are shown in \(localName), \(hours) \(plural) \(direction) UK racing time."
    }
}
