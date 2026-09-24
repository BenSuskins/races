import SwiftUI
import RacesKit

/// What the model is and what it weighs, in full.
///
/// The point of this screen is that the recommendation is not a black box. Every
/// number the rater uses is here, including the four factors that ship at zero
/// and the guardrails that throw a market away. A tipping app that cannot show
/// you this is asking to be trusted rather than checked.
struct AlgorithmView: View {
    @State private var model: AlgorithmViewModel

    init(environment: AppEnvironment) {
        _model = State(initialValue: AlgorithmViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Every race starts from the exchange's own implied probability — the best public estimate there is — and is then nudged by what the racecard says. It is not a tipping service reinventing the odds; it is the market, adjusted.")
                        .font(.footnote)
                } header: {
                    Text("How it works")
                }

                blendSection
                factorSection
                guardrailSection
                formSection
                identitySection

                Section {
                    Text("For information only. Not betting advice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Model")
        }
        .task { await model.loadIfNeeded() }
    }

    // MARK: - The blend

    private var blendSection: some View {
        Section {
            ParameterRow(
                name: "β — form influence",
                value: model.formInfluence.formatted(.number.precision(.fractionLength(2))),
                detail: model.isMarketOnly
                    ? "Zero, so the model is currently reproducing the market exactly and adding nothing of its own."
                    : "How far the model may disagree with the market. This is the single most important number in it.")

            ParameterRow(
                name: "β with no market",
                value: model.formInfluenceNoMarket.formatted(.number.precision(.fractionLength(2))),
                detail: "Used when no market matched, so form has to carry the race on its own. Higher, because there is nothing else.")

            ParameterRow(
                name: "α — market exponent",
                value: model.marketExponent.formatted(.number.precision(.fractionLength(2))),
                detail: "How much of the market's shape to keep. One takes it as given.")
        } header: {
            Text("The blend")
        } footer: {
            Text("Combined in log-odds space, not by averaging probabilities, which keeps the market's shape intact. At β = 0 the output *is* the market — which is what makes \"does any of this help?\" a measurement rather than an opinion.")
        }
    }

    // MARK: - Factors

    private var factorSection: some View {
        Section {
            ForEach(model.factors) { factor in
                FactorWeightRow(factor: factor)
            }
        } header: {
            Text("Factors — \(model.liveFactorCount) of \(model.totalFactorCount) in play")
        } footer: {
            Text("Each factor is z-scored against the other runners in the same race, then weighted. Absolute scales mean nothing across races: an official rating of 80 is strong in one and modest in another.")
        }
    }

    // MARK: - Guardrails

    private var guardrailSection: some View {
        Section {
            ParameterRow(
                name: "Z-score clip",
                value: "±\(model.clip.formatted(.number.precision(.fractionLength(1))))",
                detail: "One freak reading cannot dominate a race.")

            ParameterRow(
                name: "Minimum market coverage",
                value: model.minimumMarketCoverage.formatted(.percent.precision(.fractionLength(0))),
                detail: "Below this the market is discarded whole rather than used to anchor part of a field. A book missing three runners is not a book, and de-vigging what is left would quietly inflate everyone else.")

            ParameterRow(
                name: "Overround correction",
                value: model.overroundMethodName,
                detail: model.overroundMethodDetail)

            ParameterRow(
                name: "Strike-rate sample floor",
                value: "\(model.minimumStrikeRateSample) runs",
                detail: "A jockey or trainer stays silent until the archive holds this many runs for them. One win from one run is not a 100% strike rate.")
        } header: {
            Text("Guardrails")
        } footer: {
            Text("These exist to make the model refuse rather than guess. Every one of them can cost a recommendation, and that is the intended trade.")
        }
    }

    // MARK: - Form

    private var formSection: some View {
        Section {
            ParameterRow(
                name: "Recency decay",
                value: model.formDecay.formatted(.number.precision(.fractionLength(2))),
                detail: "Each run back counts this much of the one after it.")

            ParameterRow(
                name: "Runs considered",
                value: "\(model.formMaxRuns)",
                detail: "Read right to left: the rightmost character of a form string is the most recent run.")

            ParameterRow(
                name: "Season break",
                value: "×\(model.formSeasonBreakPenalty.formatted(.number.precision(.fractionLength(2))))",
                detail: "Everything before a \"-\" is discounted.")

            ParameterRow(
                name: "Long break",
                value: "×\(model.formLongBreakPenalty.formatted(.number.precision(.fractionLength(2))))",
                detail: "Everything before a \"/\" is discounted harder.")

            DisclosureGroup("Points per finish") {
                ForEach(model.formPoints) { point in
                    LabeledContent(
                        point.label,
                        value: point.points.formatted(.number.precision(.fractionLength(2))))
                        .font(.footnote)
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
        } header: {
            Text("Reading form")
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            LabeledContent("Model", value: model.modelVersion)
            LabeledContent("Weights", value: model.weightsID)
            if model.archivedRaceCount > 0 {
                LabeledContent("Races archived", value: "\(model.archivedRaceCount)")
            }
            if let samples = model.trainingSamples {
                LabeledContent("Races to learn from", value: model.trainingMinimum.map { "\(samples) of \($0)" } ?? "\(samples)")
            }
            if let failure = model.loadFailure {
                Label(failure.errorDescription ?? "Couldn't reach the server.", systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Version")
        } footer: {
            Text("These are the weights the server is running. Both ids are stamped onto every tip, and the server only changes weights by minting a new id — retraining nightly once enough races have settled, and promoting a new set only when it beats the current one on races it never saw.")
        }
    }
}

/// A named number with its reason underneath.
///
/// The reason is not optional and not a disclosure triangle. A screen of bare
/// coefficients is not an explanation, and this screen's only job is explaining.
private struct ParameterRow: View {
    let name: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                Spacer(minLength: 8)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct FactorWeightRow: View {
    let factor: AlgorithmViewModel.FactorRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(factor.id.label)
                    .foregroundStyle(factor.isActive ? .primary : .secondary)
                Spacer(minLength: 8)
                Text(factor.weight.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                    .foregroundStyle(factor.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }

            // Only for factors that carry weight. A zero-weight bar is a blank
            // line pretending to be a measurement.
            if factor.weight > 0 {
                WeightBar(fraction: factor.relative, isActive: factor.isActive)
            }

            Text(factor.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let reason = factor.inactiveReason {
                Label(reason, systemImage: "pause.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let rationale = factor.rationale {
                Label(rationale, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct WeightBar: View {
    let fraction: Double
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: max(2, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
