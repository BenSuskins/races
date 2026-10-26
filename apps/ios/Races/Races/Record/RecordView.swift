import SwiftUI
import RacesKit

/// How the tips have actually done — including the ways they haven't.
///
/// The layout is deliberate: the favourite baseline sits immediately beneath the
/// strike rate, because a 32% strike rate means nothing until you know the
/// favourite won 34% of the same races. Coverage is shown whether or not it is
/// good, so a record built from a partial sample cannot pass as a full one.
struct RecordView: View {
    @State private var model: RecordViewModel

    init(environment: AppEnvironment) {
        _model = State(initialValue: RecordViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            StateContentView(state: model.state, retry: { await model.load() }) { report in
                if report.total == 0 {
                    ContentUnavailableView(
                        "No tips yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("The server records a tip for every race five minutes before the off and settles it after racing. History from before the server can be uploaded in Settings."))
                } else {
                    List {
                        weightsSelector
                        headline(report)
                        baseline(report)
                        split(report)
                        calibration(report)
                        coverage(report)
                        recentRaces
                        footer
                    }
                    .refreshable { await model.refresh() }
                }
            }
            .navigationTitle("Record")
            .toolbar {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshingResults {
                        ProgressView()
                    } else {
                        Label("Fetch results", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshingResults)
            }
        }
        .task { await model.loadIfNeeded() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var weightsSelector: some View {
        if !model.weightsInUse.isEmpty {
            Section("Weight set") {
                Picker("Population", selection: selectedWeightsBinding) {
                    ForEach(model.weightsInUse.keys.sorted(), id: \.self) { weightsID in
                        Text(weightsID == model.activeWeightsID ? "\(weightsID) (active)" : weightsID)
                            .tag(weightsID)
                    }
                }
            }
        }
    }

    private var selectedWeightsBinding: Binding<String> {
        Binding(
            get: { model.selectedWeightsID ?? model.activeWeightsID ?? "" },
            set: { weightsID in Task { await model.selectWeights(weightsID) } }
        )
    }

    @ViewBuilder
    private func headline(_ report: AccuracyReport) -> some View {
        Section {
            LabeledContent("Settled", value: "\(report.settled)")
            LabeledContent("Won", value: "\(report.wins)")
            LabeledContent("Strike rate", value: percent(report.strikeRate))
        } header: {
            Text("The model")
        } footer: {
            if let staleSince = model.staleSince {
                Text("Couldn't reach the server — showing the record saved \(staleSince.formatted(date: .omitted, time: .shortened)).")
            } else if model.uploadedTipCount > 0 {
                Text("Includes \(model.uploadedTipCount) tips uploaded from this phone's history before the server existed.")
            }
        }
    }

    /// The most important number in the app.
    @ViewBuilder
    private func baseline(_ report: AccuracyReport) -> some View {
        let model = report.benchmarkedModel ?? .empty
        Section {
            LabeledContent("Model, benchmarked races") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(percent(model.strikeRate)).monospacedDigit()
                    Text("\(model.wins)/\(model.settled)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Text(interval(report.modelWilson)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Favourite, same races") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(percent(report.favouriteBaseline.strikeRate)).monospacedDigit()
                    Text("\(report.favouriteBaseline.wins)/\(report.favouriteBaseline.settled)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Text(interval(report.favouriteWilson)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let beats = report.beatsFavouriteOnStrikeRate {
                LabeledContent("Beating the favourite") {
                    Text(beats ? "Yes" : "No")
                        .foregroundStyle(beats ? .green : .red)
                }
            }
        } header: {
            Text("The benchmark")
        } footer: {
            Text("Backing the market favourite in the same races. If the model can't beat this, it isn't adding anything — which is worth knowing early rather than late.")
        }
    }

    /// Where the model actually earned or lost its keep.
    @ViewBuilder
    private func split(_ report: AccuracyReport) -> some View {
        Section {
            subset("Agreed with favourite", report.whenAgreeingWithFavourite)
            subset("Disagreed", report.whenDisagreeing)
        } header: {
            Text("Agreement split")
        } footer: {
            Text("When the tip was the favourite, the model contributed nothing you couldn't get from the market. All of its information is in the races where it disagreed.")
        }
    }

    @ViewBuilder
    private func subset(_ title: String, _ performance: SubsetPerformance) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(percent(performance.strikeRate)).monospacedDigit()
                Text("\(performance.wins)/\(performance.settled)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func calibration(_ report: AccuracyReport) -> some View {
        Section {
            LabeledContent("Predicted strike rate", value: percent(report.expectedStrikeRate))
            if let brier = report.brierScore {
                LabeledContent("Brier score",
                               value: brier.formatted(.number.precision(.fractionLength(3))))
            }
            if report.isSufficientSampleForROI, let roi = report.roi, let percentage = roi.percentage {
                LabeledContent("ROI to level stakes",
                               value: percentage.formatted(.percent.precision(.fractionLength(1))))
            }
        } header: {
            Text("Calibration")
        } footer: {
            Text(roiFooter(report))
        }
    }

    private func roiFooter(_ report: AccuracyReport) -> String {
        if !report.isSufficientSampleForROI {
            return "ROI appears once \(AccuracyReport.minimumSampleForROI) tips have settled — over fewer than that it is noise, and reading it as a result would be a mistake. Saying the model should hit X% and hitting X% is the thing to watch until then."
        }
        if report.settledWithoutPrice > 0 {
            return "\(report.settledWithoutPrice) settled tips have no starting price and sit outside the ROI figure. Betfair SP would fill those in."
        }
        return "Predicted against actual. A model saying 25% and hitting 25% is working, whatever the prices did."
    }

    @ViewBuilder
    private func coverage(_ report: AccuracyReport) -> some View {
        Section {
            LabeledContent("Results seen", value: percent(report.coverage))
            if report.pending > 0 {
                LabeledContent("Still to run", value: "\(report.pending)")
            }
            if report.unresolved > 0 {
                LabeledContent("Awaiting a result", value: "\(report.unresolved)")
            }
            if report.expired > 0 {
                LabeledContent("Never resolved", value: "\(report.expired)")
            }
            if report.voided > 0 {
                LabeledContent("Void", value: "\(report.voided)")
            }
            LabeledContent("Races archived", value: "\(model.archivedRaceCount)")
        } header: {
            Text("Coverage")
        } footer: {
            Text("Free results cover today only. The server polls them all evening, but a day it misses is a result lost for good. Those tips expire and are counted here rather than dropped — otherwise the record would quietly become a flattering subsample.")
        }
    }

    @ViewBuilder
    private var recentRaces: some View {
        if !model.recentTips.isEmpty {
            Section {
                ForEach(model.recentTips) { tip in
                    DisclosureGroup {
                        LabeledContent("Result", value: outcomeLabel(tip.outcome))
                        LabeledContent("Model chance", value: percent(tip.predictedProbability))
                        if let marketProbability = tip.marketProbabilityAtTip {
                            LabeledContent("Market chance", value: percent(marketProbability))
                        }
                        if let marketBackPrice = tip.marketBackPriceAtTip {
                            LabeledContent("Price at tip", value: marketBackPrice.formatted(.number.precision(.fractionLength(2))))
                        }
                        if let outcome = tip.outcome, let price = outcome.betfairSP {
                            LabeledContent("Starting price", value: price.formatted(.number.precision(.fractionLength(2))))
                        }
                        if let agreed = tip.agreedWithFavourite {
                            LabeledContent("Market favourite", value: agreed ? "Model selected the favourite" : "Model selected another horse")
                        }
                        LabeledContent("Weight set", value: tip.weightsID)
                        if !tip.contributions.isEmpty {
                            Text("Why the model chose this horse")
                                .font(.subheadline.weight(.semibold))
                                .padding(.top, 6)
                            ForEach(tip.contributions) { contribution in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contribution.label)
                                        .font(.subheadline)
                                    Text(contribution.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(tip.courseName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(outcomeLabel(tip.outcome))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(outcomeColor(tip.outcome))
                            }
                            Text(tip.raceName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(tip.selectionHorseName)
                                Spacer()
                                Text(tip.offAt?.formatted(date: .abbreviated, time: .shortened) ?? tip.raceDate)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Recent completed races")
            } footer: {
                Text("The latest 30 races with a settled result in this weight set. Expand a race to compare the frozen tip with the result.")
            }
        }
    }

    private func outcomeLabel(_ outcome: TipOutcome?) -> String {
        guard let outcome else { return "Pending" }
        switch outcome {
        case .won: return "Won"
        case .lost(let position, _):
            return position.map { "Finished \($0)" } ?? "Lost"
        case .nonRunner: return "Non-runner"
        case .abandoned: return "Abandoned"
        case .unresolved: return "Awaiting result"
        case .expired: return "Expired"
        }
    }

    private func outcomeColor(_ outcome: TipOutcome?) -> Color {
        guard let outcome else { return .secondary }
        switch outcome {
        case .won: return .green
        case .lost: return .primary
        case .nonRunner, .abandoned, .unresolved, .expired: return .secondary
        }
    }

    @ViewBuilder
    private var footer: some View {
        Section {
            EmptyView()
        } footer: {
            Text("For information only. Not betting advice. The record lives on the server; nothing here can delete it.")
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(1)))
    }

    private func interval(_ value: WilsonInterval?) -> String {
        guard let value else { return "95% interval unavailable" }
        return "95%: \(percent(value.lower))–\(percent(value.upper))"
    }
}
