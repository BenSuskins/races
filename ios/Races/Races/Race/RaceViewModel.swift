import Foundation
import RacesKit

/// The model's opinion of one race, for display.
///
/// Assessment only — this screen never records a tip. `TipsViewModel` records the
/// whole card, which keeps the accuracy record a complete sample of every race
/// rather than a sample of the races the user happened to tap on. Recording here
/// too would bias the record toward races that looked interesting.
@Observable
@MainActor
final class RaceViewModel {

    let race: Race
    private(set) var assessment: RaceAssessment?

    private let store: RacesStore?

    init(race: Race, store: RacesStore?) {
        self.race = race
        self.store = store
    }

    func loadIfNeeded() async {
        guard assessment == nil, let store else { return }
        await store.loadIfNeeded()
        assessment = await store.assess(race)
    }

    func assessment(forHorse horseID: String) -> RunnerAssessment? {
        assessment?.runners.first { $0.horseID == horseID }
    }
}
