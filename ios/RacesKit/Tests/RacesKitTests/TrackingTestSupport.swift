import Foundation
@testable import RacesKit

extension TipRecord {
    /// A tip with sensible defaults, so each test states only what it is about.
    static func make(
        raceID: String = "rac_1",
        selection: String = "hrs_1",
        offAt: Date? = Date(timeIntervalSince1970: 1_800_000_000),
        predictedProbability: Double = 0.30,
        marketFavouriteHorseID: String? = "hrs_1",
        agreedWithFavourite: Bool? = true,
        createdAt: Date = Date(timeIntervalSince1970: 1_799_990_000),
        sealedAt: Date? = nil,
        outcome: TipOutcome? = nil,
        favouriteOutcome: FavouriteOutcome? = nil
    ) -> TipRecord {
        TipRecord(
            raceID: raceID,
            raceDate: "2026-09-20",
            offAt: offAt,
            courseName: "Ascot",
            raceName: "Test Handicap",
            raceType: .flat,
            fieldSizeAtTip: 8,
            selectionHorseID: selection,
            selectionHorseName: selection.capitalized,
            predictedProbability: predictedProbability,
            marketProbabilityAtTip: 0.28,
            marketBackPriceAtTip: 3.5,
            marketFavouriteHorseID: marketFavouriteHorseID,
            agreedWithFavourite: agreedWithFavourite,
            wasFormOnly: false,
            confidence: .medium,
            modelVersion: RaceRater.modelVersion,
            weightsID: "v1",
            contributions: [],
            createdAt: createdAt,
            sealedAt: sealedAt,
            outcome: outcome,
            favouriteOutcome: favouriteOutcome
        )
    }
}

enum TestResult {
    /// A settled race. `finishing` maps horse id to the position string as the
    /// provider would send it, so "PU" and friends are expressible.
    static func result(
        id: String = "rac_1",
        finishing: [(String, String)],
        startingPrices: [String: Double] = [:],
        jockeys: [String: String] = [:],
        trainers: [String: String] = [:]
    ) -> RaceResult {
        RaceResult(
            id: id,
            courseName: "Ascot",
            name: "Test Handicap",
            date: "2026-09-20",
            going: .good,
            surface: .turf,
            type: .flat,
            finishers: finishing.map { horseID, position in
                Finisher(
                    horseID: horseID,
                    horseName: horseID.capitalized,
                    position: FinishPosition(raw: position),
                    jockeyID: jockeys[horseID],
                    trainerID: trainers[horseID],
                    startingPriceDecimal: startingPrices[horseID]
                )
            }
        )
    }
}
