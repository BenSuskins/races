import SwiftUI
import RacesKit

/// Where the Racing tab pushes to reach the full course directory.
///
/// A route value rather than a `Bool` binding, so it lives in the same
/// navigation stack as the card and a race opened from a course drills down
/// normally. `nonisolated` because `NavigationLink(value:)` needs a plain
/// `Hashable`, which an app-side type does not get by default — see CLAUDE.md.
nonisolated struct CourseDirectoryRoute: Hashable, Sendable {}

/// Every GB and Irish course, searchable, with today's card attached where there
/// is one.
///
/// No longer a tab: iOS collapses a sixth tab into a "More" list, and burying
/// Settings — where credentials are entered — to surface a reference list was the
/// wrong trade. It is pushed from Racing instead, which is also where someone
/// looking for a course actually starts. Racing's own search covers today's
/// meetings; this covers the ones with no fixture, which is the only thing the
/// card cannot tell you.
struct CoursesView: View {
    @State private var model: CoursesViewModel
    @State private var query = ""

    init(environment: AppEnvironment) {
        _model = State(initialValue: CoursesViewModel(environment: environment))
    }

    var body: some View {
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
        .navigationTitle("All courses")
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

/// One course's card for today.
struct CourseView: View {
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
