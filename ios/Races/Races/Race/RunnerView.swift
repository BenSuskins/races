import SwiftUI
import RacesKit

/// One runner in full: its card details and its form, run by run.
///
/// Absent values are omitted rather than shown as zero or a dash where that
/// could be read as a fact. An unraced two-year-old has no official rating and no
/// form, and the honest presentation of that is silence plus one plain sentence —
/// not "OR 0", which would libel the horse.
struct RunnerView: View {
    let runner: Runner
    let race: Race

    private var form: FormLine { FormParser.parse(runner.form) }

    /// The rank of this runner's mark among the marks in today's race.
    ///
    /// Only runners that *have* a mark are counted, so the denominator is "rated
    /// runners" rather than the field size — in a race where half the field is
    /// unraced, "3rd of 12" would be a claim the data cannot support.
    private var officialRatingContext: String? {
        guard let officialRating = runner.officialRating else { return nil }
        return RatingContext.describe(
            officialRating,
            among: race.declaredRunners.compactMap(\.officialRating))
    }

    var body: some View {
        List {
            Section("Card") {
                if let clothNumber = runner.clothNumber {
                    LabeledContent("Cloth", value: "\(clothNumber)")
                }
                if let draw = runner.draw {
                    LabeledContent("Draw", value: "\(draw)")
                }
                if let age = runner.age {
                    LabeledContent("Age", value: "\(age)")
                }
                if let sex = runner.sex, !sex.isEmpty {
                    LabeledContent("Sex", value: sex)
                }
                if let officialRating = runner.officialRating {
                    LabeledContent("Official rating") {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(officialRating)").monospacedDigit()
                            if let context = officialRatingContext {
                                Text(context)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let weight = runner.weightDisplay {
                    LabeledContent("Weight", value: weight)
                }
                if runner.wearsHeadgear, let headgear = runner.headgear {
                    LabeledContent("Headgear", value: headgear.uppercased())
                }
                if let daysSinceLastRun = runner.daysSinceLastRun {
                    LabeledContent("Last run", value: daysSinceLastRun == 0
                        ? "Today"
                        : "\(daysSinceLastRun) day\(daysSinceLastRun == 1 ? "" : "s") ago")
                }
            }

            Section("Connections") {
                if let jockeyName = runner.jockeyName {
                    LabeledContent("Jockey", value: jockeyName)
                }
                if let trainerName = runner.trainerName {
                    LabeledContent("Trainer", value: trainerName)
                }
                if let ownerName = runner.ownerName {
                    LabeledContent("Owner", value: ownerName)
                }
                if let sireName = runner.sireName {
                    LabeledContent("Sire", value: sireName)
                }
                if let damName = runner.damName {
                    LabeledContent("Dam", value: damName)
                }
            }

            formSection

            if runner.racingPostRating == nil && runner.topspeedRating == nil {
                Section {
                    Text("Expert ratings and full form history aren't on the free plan. This page shows everything today's racecard carries.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Expert ratings") {
                    if let racingPostRating = runner.racingPostRating {
                        LabeledContent("RPR", value: "\(racingPostRating)")
                    }
                    if let topspeedRating = runner.topspeedRating {
                        LabeledContent("Topspeed", value: "\(topspeedRating)")
                    }
                }
            }

            if let spotlight = runner.spotlight, !spotlight.isEmpty {
                Section("Spotlight") {
                    Text(spotlight).font(.callout)
                }
            }
        }
        .navigationTitle(runner.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var formSection: some View {
        if form.isEmpty {
            Section("Form") {
                Text(runner.form?.isEmpty == false
                    ? "Form figures unreadable."
                    : "No form — this looks like a first run.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                // Reversed, because the provider sends oldest-first and the label
                // below is the only thing that tells the user which way to read it.
                ForEach(Array(form.outcomes.reversed().enumerated()), id: \.offset) { index, outcome in
                    LabeledContent {
                        Text(FormDisplay.describe(outcome))
                            .foregroundStyle(outcome.isWin ? .primary : .secondary)
                    } label: {
                        Text(index == 0 ? "Latest" : "\(index) back")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Form — most recent first")
            } footer: {
                Text(footerText)
            }
        }
    }

    private var footerText: String {
        var parts = ["\(form.runCount) run\(form.runCount == 1 ? "" : "s") on the card"]
        if let completionRate = form.completionRate, completionRate < 1 {
            parts.append("completed \(Int(completionRate * 100))%")
        }
        if form.hasLongBreak {
            parts.append("has had a long break")
        }
        return parts.joined(separator: " · ") + "."
    }
}
