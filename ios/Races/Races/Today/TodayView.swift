import SwiftUI
import RacesKit

/// Today's or tomorrow's racing, by meeting.
struct TodayView: View {
    private let environment: AppEnvironment
    @State private var model: TodayViewModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: TodayViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Day", selection: Binding(
                    get: { model.day },
                    set: { day in Task { await model.select(day) } }
                )) {
                    Text("Today").tag(RaceDay.today)
                    Text("Tomorrow").tag(RaceDay.tomorrow)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                StateContentView(state: model.state, retry: { await model.load() }) { meetings in
                    if meetings.isEmpty {
                        ContentUnavailableView(
                            model.day == .today ? "No racing today" : "No racing tomorrow",
                            systemImage: "calendar",
                            description: Text("There are no British or Irish fixtures on this card."))
                    } else {
                        List {
                            if let staleSince = model.staleSince {
                                Section {
                                    Label(
                                        "Couldn't refresh — showing the card saved \(staleSince.formatted(date: .omitted, time: .shortened)).",
                                        systemImage: "wifi.exclamationmark")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            ForEach(meetings) { meeting in
                                Section {
                                    ForEach(meeting.races) { race in
                                        NavigationLink(value: race) {
                                            RaceRow(race: race)
                                        }
                                    }
                                } header: {
                                    MeetingHeader(meeting: meeting)
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .refreshable { await model.load(forceRefresh: true) }
                    }
                }
            }
            .navigationTitle("Racing")
            .navigationDestination(for: Race.self) {
                RaceView(race: $0, environment: environment)
            }
        }
        .task { await model.loadIfNeeded() }
    }
}

private struct MeetingHeader: View {
    let meeting: Meeting

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(meeting.courseName)
                .font(.headline)
                .textCase(nil)

            Spacer(minLength: 8)

            if let next = meeting.nextRace {
                Text("Next \(next.offTime)")
                    .font(.caption)
                    .monospacedDigit()
                    .textCase(nil)
                    .foregroundStyle(.secondary)
            } else {
                Text("Finished")
                    .font(.caption)
                    .textCase(nil)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
