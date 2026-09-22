import SwiftUI
import RacesKit

/// Today's or tomorrow's racing, by meeting — and the way in to every course.
///
/// Search filters the meetings on this card, which is what someone looking for a
/// course nearly always wants. The full directory, including the courses with no
/// fixture today, is one push away rather than a tab of its own.
struct TodayView: View {
    private let environment: AppEnvironment
    @State private var model: TodayViewModel
    @State private var query = ""

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: TodayViewModel(environment: environment))
    }

    /// Meetings matching the search box. Matching on course name only: a race
    /// title search would return one race out of a meeting and read as though
    /// the rest of the card had gone.
    private func filtered(_ meetings: [Meeting]) -> [Meeting] {
        guard !query.isEmpty else { return meetings }
        return meetings.filter { $0.courseName.localizedCaseInsensitiveContains(query) }
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
                        // The directory link belongs here too. Without it, a day
                        // with no fixtures leaves the only route to the course
                        // list unreachable — and a blank day is exactly when
                        // someone goes looking for one.
                        ContentUnavailableView {
                            Label(
                                model.day == .today ? "No racing today" : "No racing tomorrow",
                                systemImage: "calendar")
                        } description: {
                            Text("There are no British or Irish fixtures on this card.")
                        } actions: {
                            NavigationLink(value: CourseDirectoryRoute()) {
                                Text("Browse all courses")
                            }
                        }
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

                            ForEach(filtered(meetings)) { meeting in
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

                            Section {
                                NavigationLink(value: CourseDirectoryRoute()) {
                                    Label("All courses", systemImage: "map")
                                }
                            } footer: {
                                Text("Every British and Irish course, including the ones not racing today.")
                            }
                        }
                        .listStyle(.insetGrouped)
                        .searchable(text: $query, prompt: "Course name")
                        .overlay {
                            if filtered(meetings).isEmpty && !query.isEmpty {
                                ContentUnavailableView.search(text: query)
                            }
                        }
                        .refreshable { await model.load(forceRefresh: true) }
                    }
                }
            }
            .navigationTitle("Racing")
            .navigationDestination(for: Race.self) {
                RaceView(race: $0, environment: environment)
            }
            // Both destinations are declared here, at the root of the stack,
            // rather than inside the pushed course list. A destination declared
            // in a pushed view is only available from that level down, which
            // would work today and break the moment something links to a course
            // from this screen.
            .navigationDestination(for: CourseDirectoryRoute.self) { _ in
                CoursesView(environment: environment)
            }
            .navigationDestination(for: CoursesViewModel.CourseListing.self) { listing in
                CourseView(listing: listing)
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
