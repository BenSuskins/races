import Foundation
import RacesKit

/// One race and the model's view of it.
///
/// The assessment is the server's: the one it last drafted, or the one it
/// sealed the tip on. Nothing is rated on the phone, so what this screen shows
/// and what the record is judged on cannot disagree.
@Observable
@MainActor
final class RaceViewModel {

    let race: Race
    private(set) var assessment: RaceAssessment?
    /// Why the race has no market, when the matcher refused one.
    private(set) var refusal: ServerRefusal?
    private(set) var tip: TipRecord?

    private let link: ServerLink

    init(race: Race, link: ServerLink) {
        self.race = race
        self.link = link
    }

    convenience init(race: Race, environment: AppEnvironment) {
        self.init(race: race, link: environment.link)
    }

    func loadIfNeeded() async {
        guard assessment == nil, let server = link.server else { return }
        // A failure leaves the card on screen without a model view, which is
        // what the race looks like with no server at all.
        guard let detail = try? await server.race(id: race.id) else { return }
        assessment = detail.assessment
        refusal = detail.refusal
        tip = detail.tip
    }

    func assessment(forHorse horseID: String) -> RunnerAssessment? {
        assessment?.runners.first { $0.horseID == horseID }
    }
}
