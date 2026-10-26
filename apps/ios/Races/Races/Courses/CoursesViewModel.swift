import Foundation
import RacesKit

/// Every course, with today's races attached where there are any.
///
/// Courses and today's card are two separate calls, and a course list with no
/// racing today is still worth showing — so the two are loaded together but a
/// failure to get the card does not fail the screen. The list degrades to names
/// only, which is the browse equivalent of the form-only fallback.
@Observable
@MainActor
final class CoursesViewModel {

    nonisolated struct CourseListing: Identifiable, Hashable {
        let course: Course
        let races: [Race]

        var id: String { course.id }
        var hasRacingToday: Bool { !races.isEmpty }
    }

    private(set) var state: ViewState<[CourseListing]> = .idle
    /// Set when the course list loaded but today's card did not. The screen is
    /// usable, so this is a note rather than an error state.
    private(set) var cardUnavailable: APIError?

    private let link: ServerLink
    private let racecards: RacecardLoader

    init(link: ServerLink, racecards: RacecardLoader) {
        self.link = link
        self.racecards = racecards
    }

    convenience init(environment: AppEnvironment) {
        self.init(link: environment.link, racecards: environment.racecards)
    }

    func loadIfNeeded() async {
        guard state.value == nil else { return }
        await load()
    }

    func load() async {
        if state.value == nil {
            state = .loading
        }

        let courses: [Course]
        do {
            courses = try await link.require().courses()
        } catch {
            state = .failed(.from(error))
            return
        }

        var racesByCourseName: [String: [Race]] = [:]
        do {
            let races = try await racecards.load(day: .today).races
            racesByCourseName = Dictionary(grouping: races) {
                CourseNameNormaliser.key($0.courseName)
            }
            cardUnavailable = nil
        } catch {
            // The course list is the screen's content; today's card is a bonus.
            cardUnavailable = .from(error)
        }

        state = .loaded(
            courses.sortedByName.map { course in
                CourseListing(
                    course: course,
                    races: racesByCourseName[CourseNameNormaliser.key(course.name)] ?? [])
            })
    }
}
