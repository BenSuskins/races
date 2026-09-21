import SwiftUI
import RacesKit

/// Today's racing, by meeting, with the next race off highlighted.
struct TodayView: View {
    @State private var model: TodayViewModel

    init(environment: AppEnvironment) {
        _model = State(initialValue: TodayViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            StateContentView(state: model.state, retry: { await model.load() }) { meetings in
                if meetings.isEmpty {
                    ContentUnavailableView(
                        "No racing today",
                        systemImage: "calendar",
                        description: Text("There are no British or Irish fixtures on today's card."))
                } else {
                    List {
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
                    .refreshable { await model.load() }
                }
            }
            .navigationTitle("Today")
            .navigationDestination(for: Race.self) { RaceView(race: $0) }
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
