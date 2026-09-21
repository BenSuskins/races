import SwiftUI
import RacesKit

/// Every course, searchable, with today's card attached where there is one.
struct CoursesView: View {
    private let environment: AppEnvironment
    @State private var model: CoursesViewModel
    @State private var query = ""

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: CoursesViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            StateContentView(state: model.state, retry: { await model.load() }) { listings in
                List {
                    if let cardUnavailable = model.cardUnavailable {
                        Section {
                            Label(
                                cardUnavailable.errorDescription ?? "Today's card is unavailable.",
                                systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(filtered(listings)) { listing in
                        NavigationLink(value: listing) {
                            CourseRow(listing: listing)
                        }
                    }
                }
                .searchable(text: $query, prompt: "Course name")
                .overlay {
                    if filtered(listings).isEmpty && !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .refreshable { await model.load() }
            }
            .navigationTitle("Courses")
            .navigationDestination(for: CoursesViewModel.CourseListing.self) { listing in
                CourseView(listing: listing)
            }
            .navigationDestination(for: Race.self) {
                RaceView(race: $0, environment: environment)
            }
        }
        .task { await model.loadIfNeeded() }
    }

    private func filtered(_ listings: [CoursesViewModel.CourseListing]) -> [CoursesViewModel.CourseListing] {
        guard !query.isEmpty else { return listings }
        return listings.filter {
            $0.course.name.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct CourseRow: View {
    let listing: CoursesViewModel.CourseListing

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.course.name)
                Text(listing.course.region)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if listing.hasRacingToday {
                Text("\(listing.races.count) today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }
}

/// One course's card for today. Reached from the Courses tab.
private struct CourseView: View {
    let listing: CoursesViewModel.CourseListing

    var body: some View {
        Group {
            if listing.races.isEmpty {
                ContentUnavailableView(
                    "No racing today",
                    systemImage: "calendar",
                    description: Text("\(listing.course.name) has no fixture on today's card."))
            } else {
                List {
                    ForEach(listing.races.sorted { ($0.offDateTime ?? .distantFuture) < ($1.offDateTime ?? .distantFuture) }) { race in
                        NavigationLink(value: race) {
                            RaceRow(race: race)
                        }
                    }
                }
            }
        }
        .navigationTitle(listing.course.name)
    }
}
