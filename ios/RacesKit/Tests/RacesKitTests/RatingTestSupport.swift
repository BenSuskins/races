import Foundation
@testable import RacesKit

/// Builders so rating tests read as the thing they are testing rather than as
/// twenty lines of struct construction.
enum TestRace {

    static func runner(
        _ id: String,
        name: String? = nil,
        number: Int? = nil,
        draw: Int? = nil,
        age: Int? = 5,
        officialRating: Int? = nil,
        weightPounds: Int? = 133,
        headgear: String? = nil,
        form: String? = nil,
        daysSinceLastRun: Int? = 21,
        jockeyID: String? = nil,
        trainerID: String? = nil
    ) -> Runner {
        Runner(
            id: id,
            name: name ?? id.capitalized,
            clothNumber: number,
            draw: draw,
            age: age,
            officialRating: officialRating,
            weightPounds: weightPounds,
            headgear: headgear,
            form: form,
            daysSinceLastRun: daysSinceLastRun,
            jockeyID: jockeyID,
            trainerID: trainerID
        )
    }

    static func race(
        id: String = "rac_test",
        name: String = "Test Stakes",
        type: RaceType = .flat,
        surface: Surface = .turf,
        going: Going = .good,
        distance: Distance = Distance(exactFurlongs: 8),
        fieldSize: Int? = nil,
        raceClass: Int? = 3,
        ratingBand: ClosedRange<Int>? = nil,
        ageBand: String? = "3yo+",
        runners: [Runner]
    ) -> Race {
        Race(
            id: id,
            courseName: "Ascot",
            name: name,
            offTime: "14:30",
            date: "2026-09-20",
            distance: distance,
            going: going,
            surface: surface,
            type: type,
            raceClass: raceClass,
            ageBand: ageBand,
            ratingBand: ratingBand,
            fieldSize: fieldSize ?? runners.count,
            runners: runners
        )
    }

    /// A market built straight from decimal back prices, keyed by horse id.
    static func market(
        _ backPrices: [String: Double],
        source: MarketSnapshot.Source = .liveExchange
    ) -> MarketSnapshot {
        MarketSnapshot(
            marketID: "1.234",
            source: source,
            prices: backPrices.mapValues { RunnerPrice(backPrice: $0) }
        )
    }
}

/// A strike-rate source with whatever records a test wants it to have.
struct FakeStrikeRates: StrikeRateProviding {
    var jockeys: [String: StrikeRate] = [:]
    var trainers: [String: StrikeRate] = [:]
    var baselineStrikeRate: Double = 0.10

    func jockeyStrikeRate(id: String) -> StrikeRate? { jockeys[id] }
    func trainerStrikeRate(id: String) -> StrikeRate? { trainers[id] }
}
