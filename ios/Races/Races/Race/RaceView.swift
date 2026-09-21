import SwiftUI
import RacesKit

/// One race's card: the conditions, then every declared runner.
///
/// Runners are in racecard order — by cloth number — not in any order of merit.
/// The model's opinion arrives with the rating milestone, and until it does this
/// screen must not imply one, because a list that looks ranked *is* a tip.
struct RaceView: View {
    @State private var model: RaceViewModel

    init(race: Race, environment: AppEnvironment) {
        _model = State(initialValue: RaceViewModel(race: race, store: environment.store))
    }

    private var race: Race { model.race }

    var body: some View {
        List {
            if let assessment = model.assessment, let selection = assessment.selection {
                Section {
                    SelectionCard(assessment: assessment, selection: selection)
                } header: {
                    Text("The model fancies")
                } footer: {
                    Text(assessment.isFormOnly
                        ? "Form only — Betfair isn't connected, so there's no market to anchor this to. Treat it as a read of the racecard, nothing more."
                        : "Anchored to the market and adjusted on form.")
                }
            }

            Section("Conditions") {
                if let distance = race.distance {
                    LabeledContent("Distance", value: distance.displayString)
                }
                if race.going != .unknown {
                    LabeledContent("Going", value: race.going.displayName)
                }
                if race.surface != .unknown {
                    LabeledContent("Surface", value: race.surface.displayName)
                }
                if race.type != .unknown {
                    LabeledContent("Type", value: race.type.displayName)
                }
                if let raceClass = race.raceClass {
                    LabeledContent("Class", value: "\(raceClass)")
                }
                if let pattern = race.pattern, !pattern.isEmpty {
                    LabeledContent("Pattern", value: pattern)
                }
                if let ageBand = race.ageBand, !ageBand.isEmpty {
                    LabeledContent("Age", value: ageBand)
                }
                if let prize = race.prize, !prize.isEmpty {
                    LabeledContent("Prize", value: prize)
                }
                if race.isHandicap {
                    LabeledContent("Handicap", value: "Yes")
                }
            }

            Section {
                ForEach(race.declaredRunners) { runner in
                    NavigationLink(value: runner) {
                        RunnerRow(
                            runner: runner,
                            assessment: model.assessment(forHorse: runner.id))
                    }
                }
            } header: {
                Text("\(race.runnerCount) runners")
            } footer: {
                // Racecard order, always. A list that looks ranked is a tip, and
                // the ranking belongs in the card above where it is labelled.
                Text("In racecard order. The percentage is the model's chance for each runner.")
            }
        }
        .navigationTitle("\(race.offTime) \(race.courseName)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Runner.self) { runner in
            RunnerView(
                runner: runner,
                race: race,
                assessment: model.assessment(forHorse: runner.id),
                isFormOnly: model.assessment?.isFormOnly ?? true)
        }
        .task { await model.loadIfNeeded() }
    }
}

/// The selection, with the honest caveats attached rather than implied.
private struct SelectionCard: View {
    let assessment: RaceAssessment
    let selection: RunnerAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.horseName)
                        .font(.title3.weight(.semibold))
                    Text("\(assessment.confidence.displayName) confidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ProbabilityBadge(probability: selection.winProbability)
            }

            if let marketProbability = selection.marketProbability {
                LabeledContent(
                    "Market",
                    value: marketProbability.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RunnerRow: View {
    let runner: Runner
    let assessment: RunnerAssessment?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(runner.clothNumber.map(String.init) ?? "–")
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 24, alignment: .trailing)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(runner.name)
                        .font(.body.weight(.medium))
                    if runner.wearsHeadgear, let headgear = runner.headgear {
                        Text(headgear.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .rect(cornerRadius: 3))
                    }
                }

                if let connections = connectionsLine {
                    Text(connections)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    if let assessment {
                        Text(assessment.winProbability.formatted(
                            .percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                    }
                    if let officialRating = runner.officialRating {
                        Text("OR \(officialRating)").monospacedDigit()
                    }
                    if let weight = runner.weightDisplay {
                        Text(weight).monospacedDigit()
                    }
                    if let form = runner.form, !form.isEmpty {
                        Text(FormDisplay.mostRecentFirst(form))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionsLine: String? {
        let parts = [runner.jockeyName, runner.trainerName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
