import SwiftUI
import RacesKit

/// One race as it appears in a list: time, title, and the facts that decide
/// whether you look closer.
struct RaceRow: View {
    let race: Race
    /// Meetings already group by course, so the row would repeat it needlessly.
    var showsCourse: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(race.offTime)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(race.hasStarted ? .secondary : .primary)

                if showsCourse {
                    Text(race.courseName)
                        .font(.headline)
                }

                Spacer(minLength: 0)

                if race.hasStarted {
                    Text("Off")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(race.name)
                .font(.subheadline)
                .foregroundStyle(showsCourse ? .secondary : .primary)
                .lineLimit(2)

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Built by joining only what's present. On the free tier several of these are
    /// routinely absent, and an empty separator reads as a data bug.
    private var summary: String {
        var parts: [String] = []
        if let distance = race.distance { parts.append(distance.displayString) }
        if race.type != .unknown { parts.append(race.type.displayName) }
        if let raceClass = race.raceClass { parts.append("Class \(raceClass)") }
        parts.append("\(race.runnerCount) ran")
        return parts.joined(separator: " · ")
    }
}
