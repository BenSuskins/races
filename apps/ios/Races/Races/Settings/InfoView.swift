import SwiftUI
import RacesKit

struct InfoView: View {
    @State private var model: InfoViewModel

    init(environment: AppEnvironment) {
        _model = State(initialValue: InfoViewModel(environment: environment))
    }

    var body: some View {
        Form {
            if let failure = model.loadFailure {
                Section {
                    Label(failure.errorDescription ?? "Couldn't load server information.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Check the server connection in Settings, then pull to refresh.")
                }
            }

            Section {
                ForEach(ScheduledJob.all) { scheduled in
                    ScheduledJobRow(job: scheduled, runs: model.jobs)
                }
            } header: {
                Text("Scheduled jobs")
            } footer: {
                Text("Times use London time. The server reports the last run for each job.")
            }

            Section {
                if model.backtests.isEmpty {
                    ContentUnavailableView("No reports yet", systemImage: "chart.bar.doc.horizontal", description: Text("Stored back-test results appear here after the server runs a baseline or sweep."))
                } else {
                    ForEach(model.backtests.prefix(20)) { backtest in
                        BacktestRow(backtest: backtest)
                    }
                }
            } header: {
                Text("Recent back-test reports")
            } footer: {
                Text("Reports compare the model with the favourite on the same races. A small sample does not support a promotion decision.")
            }
        }
        .navigationTitle("Server info")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { await model.load() }
    }
}

private struct ScheduledJob: Identifiable {
    let id: String
    let title: String
    let schedule: String

    static let all = [
        ScheduledJob(id: "courses", title: "Course directory", schedule: "Daily at 06:00"),
        ScheduledJob(id: "cards-today", title: "Today’s race cards", schedule: "Every 15 minutes, 06:00–22:59"),
        ScheduledJob(id: "cards-tomorrow", title: "Tomorrow’s race cards", schedule: "Hourly, 06:00–22:00"),
        ScheduledJob(id: "markets-today", title: "Today’s markets", schedule: "Every 15 minutes, 06:00–22:59"),
        ScheduledJob(id: "markets-tomorrow", title: "Tomorrow’s markets", schedule: "Hourly, 06:00–22:00"),
        ScheduledJob(id: "draft-today", title: "Today’s draft tips", schedule: "Every 15 minutes, 06:00–22:59"),
        ScheduledJob(id: "draft-tomorrow", title: "Tomorrow’s draft tips", schedule: "Hourly, 06:00–22:00"),
        ScheduledJob(id: "seal", title: "Seal tips", schedule: "Every minute"),
        ScheduledJob(id: "results", title: "Collect results", schedule: "Every 15 minutes from 12:00; final run at 23:55"),
        ScheduledJob(id: "baseline-backtest", title: "Baseline back-test", schedule: "Daily at 02:45"),
        ScheduledJob(id: "train", title: "Train model", schedule: "Daily at 03:00"),
    ]
}

private struct ScheduledJobRow: View {
    let job: ScheduledJob
    let runs: [ServerJobRun]

    private var run: ServerJobRun? { runs.first { $0.name == job.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(job.title)
                .font(.body)
            Text(job.schedule)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let run {
                if let error = run.error, !error.isEmpty {
                    Label("Failed · \(run.finishedAt?.formatted(date: .abbreviated, time: .shortened) ?? "time unavailable")", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                } else if let succeededAt = run.succeededAt {
                    Label("Last succeeded · \(succeededAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let summary = run.summary, !summary.isEmpty {
                        Text(summary).font(.caption2).foregroundStyle(.secondary)
                    }
                } else if let startedAt = run.startedAt {
                    Label("Started · \(startedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No recorded run").font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                Text("No recorded run").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .textSelection(.enabled)
    }
}

private struct BacktestRow: View {
    let backtest: ServerBacktest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Report \(backtest.id)", value: backtest.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline.weight(.semibold))
            LabeledContent("Weights", value: backtest.weightsID)
                .font(.caption)
            if let variants = backtest.report.reports, !variants.isEmpty {
                ForEach(variants) { variant in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(variant.name).font(.caption.weight(.semibold))
                        PerformanceLine(title: "Model", arm: variant.report.highestProbability)
                        PerformanceLine(title: "Favourite", arm: variant.report.favourite)
                        MarketLossLine(value: variant.report.marketLogLoss)
                    }
                    .padding(.top, 3)
                }
            } else {
                PerformanceLine(title: "Model", arm: backtest.report.highestProbability)
                PerformanceLine(title: "Favourite", arm: backtest.report.favourite)
                MarketLossLine(value: backtest.report.marketLogLoss)
                if let from = backtest.report.from, let to = backtest.report.to {
                    Text("Dates: \(from) to \(to)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct PerformanceLine: View {
    let title: String
    let arm: ServerBacktestArm?

    var body: some View {
        if let arm {
            Text("\(title): \(arm.wins)/\(arm.races) wins · \(percentage(arm.strikeRate)) strike · log loss \(number(arm.logLoss)) · Brier \(number(arm.brier))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MarketLossLine: View {
    let value: Double?

    var body: some View {
        Text("Market log loss: \(number(value))")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

private func percentage(_ value: Double?) -> String {
    value.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—"
}

private func number(_ value: Double?) -> String {
    value.map { $0.formatted(.number.precision(.fractionLength(3))) } ?? "—"
}
