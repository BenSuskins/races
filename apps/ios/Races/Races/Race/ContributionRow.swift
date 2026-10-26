import SwiftUI
import RacesKit

/// One factor's contribution to a runner's probability.
///
/// Direction and size are given in words and digits, not by colour alone — this
/// is the screen whose whole job is explaining itself, and a red or green bar is
/// no explanation to anyone who cannot tell them apart.
///
/// Unavailable factors are listed with their reason rather than hidden. On the
/// free tier several are routinely absent, and a breakdown that quietly dropped
/// them would read as a fuller analysis than the data supports.
struct ContributionRow: View {
    let contribution: FactorContribution

    private var isAvailable: Bool { contribution.availability.isAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(contribution.label)
                    .font(.subheadline)
                    .foregroundStyle(isAvailable ? .primary : .secondary)

                Spacer(minLength: 8)

                Text(directionText)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(directionColour)
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }

    /// `detail` is "—" for an unavailable factor, so the reason is the only thing
    /// worth printing there.
    private var explanation: String {
        if isAvailable { return contribution.detail }
        return contribution.availability.reason ?? "Not available"
    }

    private var directionText: String {
        guard isAvailable else { return "not counted" }
        let points = contribution.probabilityDelta * 100
        guard abs(points) >= 0.05 else { return "no change" }
        let formatted = points.formatted(.number.precision(.fractionLength(1)))
        return points > 0 ? "+\(formatted) pts" : "\(formatted) pts"
    }

    private var directionColour: Color {
        guard isAvailable else { return .secondary }
        let points = contribution.probabilityDelta * 100
        guard abs(points) >= 0.05 else { return .secondary }
        return points > 0 ? .green : .red
    }
}
