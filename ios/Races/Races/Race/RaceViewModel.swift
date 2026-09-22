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
    private let markets: MarketLoader?
    private let now: () -> Date

    init(
        race: Race,
        store: RacesStore?,
        markets: MarketLoader? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.race = race
        self.store = store
        self.markets = markets
        self.now = now
    }

    convenience init(race: Race, environment: AppEnvironment) {
        self.init(race: race, store: environment.store, markets: environment.marketLoader)
    }

    func loadIfNeeded() async {
        guard assessment == nil, let store else { return }
        await store.loadIfNeeded()
        let market = await loadMarket()
        assessment = await store.assess(race, market: market)
    }

    /// The exchange's price for this one race, if it can be matched.
    ///
    /// Matching a single race rather than the card is safe: `RaceMatcher` scores
    /// candidate markets on runner overlap and refuses ties, so it does not need
    /// the rest of the day to tell two meetings at one course apart. And the
    /// loader is shared with Tips, so arriving here from that screen normally
    /// costs no request at all.
    private func loadMarket() async -> MarketSnapshot? {
        guard let markets else { return nil }
        let moment = now()
        // The market endpoints take today or tomorrow, not a date. A race
        // outside that window has no market to ask for, and guessing at the
        // nearer of the two would price it off the wrong day's card.
        guard let day = RaceDates.day(matching: race.date, now: moment) else { return nil }
        let load = await markets.load(races: [race], day: day, now: moment)
        return load.snapshot(forRace: race.id)
    }

    func assessment(forHorse horseID: String) -> RunnerAssessment? {
        assessment?.runners.first { $0.horseID == horseID }
    }
}
