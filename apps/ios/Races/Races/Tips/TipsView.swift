import SwiftUI
import RacesKit

/// Today's selections, one card per race.
struct TipsView: View {
    private let environment: AppEnvironment
    @State private var model: TipsViewModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: TipsViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            StateContentView(state: model.state, retry: { await model.load() }) { selections in
                if selections.isEmpty {
                    ContentUnavailableView(
                        "Nothing left to tip",
                        systemImage: "flag.checkered",
                        description: Text("Every race on today's card has already run."))
                } else {
                    List {
                        if let staleSince = model.staleSince {
                            Label(
                                "Couldn't reach the server — showing the card saved \(staleSince.formatted(date: .omitted, time: .shortened)).",
                                systemImage: "wifi.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(selections) { selection in
                            NavigationLink(value: selection.race) {
                                TipRow(selection: selection)
                            }
                        }

                        Section {
                            if let note = RaceTime.timeZoneNote() {
                                TimeZoneNote(note: note)
                            }
                            if let coverage = model.marketCoverage {
                                MarketCoverageRow(coverage: coverage)
                            }
                            DisclaimerFooter(archivedRaceCount: model.archivedRaceCount)
                        }
                    }
                    .refreshable { await model.load(forceRefresh: true) }
                }
            }
            .navigationTitle("Tips")
            .navigationDestination(for: Race.self) { RaceView(race: $0, environment: environment) }
        }
        .task { await model.loadIfNeeded() }
    }
}

private struct TipRow: View {
    let selection: TipsViewModel.Selection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(RaceTime.display(selection.race))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(selection.race.courseName)
                    .font(.subheadline)
                Spacer(minLength: 0)
                if selection.isSealed {
                    Label("Sealed", systemImage: "lock.fill")
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let runner = selection.selection {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(runner.horseName)
                        .font(.title3.weight(.medium))
                    Spacer(minLength: 0)
                    ProbabilityBadge(probability: runner.winProbability)
                }

                Text(confidenceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Says plainly how the number was reached. A probability with no provenance
    /// invites more trust than a form-only estimate deserves.
    private var confidenceLine: String {
        var parts: [String] = []
        if selection.assessment.isFormOnly {
            parts.append("Form only — no market")
        }
        if selection.assessment.isValuePick {
            // Otherwise a 15% pick reads as a mistake beside a 35% runner.
            let odds = selection.selection?.marketBackPrice
                .flatMap { FractionalOdds.display(decimal: $0) }
            parts.append(odds.map { "value pick at \($0)" } ?? "value pick")
        }
        parts.append(selection.assessment.confidence.displayName.lowercased())
        parts.append("\(selection.race.runnerCount) runners")
        return parts.joined(separator: " · ")
    }
}

struct ProbabilityBadge: View {
    let probability: Double

    var body: some View {
        Text(probability.formatted(.percent.precision(.fractionLength(0))))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.15), in: .capsule)
    }
}

/// How much of the card the exchange priced.
///
/// On screen whether or not it flatters. The model is market-anchored by design,
/// so a card that mostly failed to match is a card of weaker tips — and the one
/// place that is visible is here.
private struct MarketCoverageRow: View {
    let coverage: TipsViewModel.MarketCoverage

    var body: some View {
        Label(line, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var icon: String {
        coverage.hasAny ? "sterlingsign.circle" : "info.circle"
    }

    private var line: String {
        if coverage.isComplete {
            return "Every race matched a market."
        }
        if coverage.hasAny {
            return "\(coverage.pricedRaces) of \(coverage.totalRaces) races matched a market. The rest are form-only."
        }
        return "No race matched a market, so every tip is form-only."
    }
}

/// The disclaimer, plus how much the archive has learned so far.
struct DisclaimerFooter: View {
    let archivedRaceCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("For information only. Not betting advice.")
            if archivedRaceCount == 0 {
                Text("No results archived yet, so jockey and trainer records aren't in play. The server starts counting from its first evening of racing.")
            } else {
                Text("\(archivedRaceCount) races archived — jockey and trainer records are in play and sharpen with every race day.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
