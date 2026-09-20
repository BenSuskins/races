import Foundation

/// The racing-data side of the world: what is running, and what happened.
///
/// Kept separate from `MarketDataProviding` because either can be absent
/// independently — the user may not have configured Betfair, or a race may fail to
/// match between the two. Both absences are ordinary states the app is built to
/// work in, so they should not be able to break each other.
public protocol RacingDataProviding: AnyObject, Sendable {
    /// What this provider's tier allows. Narrows as tier-gated endpoints refuse.
    ///
    /// `async` because a client that caches this is an actor: the value is
    /// discovered from a 403 at runtime, so it is mutable state and needs an
    /// isolation domain.
    var capability: ProviderCapability { get async }

    func courses(regionCodes: [String]) async throws -> [Course]
    func racecards(day: RaceDay, regionCodes: [String]) async throws -> [Race]
    func results(day: RaceDay) async throws -> [RaceResult]

    /// A horse's past runs, with going, distance, class and beaten margins.
    ///
    /// **Paid tiers only.** The default implementation throws
    /// `APIError.tierUnavailable`, which callers are expected to catch and carry
    /// on without. This single method is the entire paid-tier upgrade path: a
    /// client that implements it and widens `capability` lights up the deep-form
    /// factors with no change at any call site.
    func formHistory(horseID: String) async throws -> [HorseRun]
}

extension RacingDataProviding {
    public func formHistory(horseID: String) async throws -> [HorseRun] {
        throw APIError.tierUnavailable(feature: "Form history")
    }

    public func courses() async throws -> [Course] {
        try await courses(regionCodes: ["gb"])
    }

    public func racecards(day: RaceDay) async throws -> [Race] {
        try await racecards(day: day, regionCodes: ["gb"])
    }
}

/// One past run by a horse, with the context the bare form string lacks.
///
/// This is what the free tier cannot give us. A form string says a horse finished
/// first; it cannot say whether that was a Class 7 seller or a Group 1, over what
/// trip, on what ground, or by how far. Two runners showing `1-121` can be forty
/// pounds apart.
public struct HorseRun: Codable, Hashable, Sendable {
    public let raceID: String
    public let date: String
    public let courseName: String
    public let courseID: String?
    public let distance: Distance?
    public let going: Going
    public let raceType: RaceType
    public let raceClass: Int?
    public let fieldSize: Int?
    public let position: FinishPosition
    /// Lengths beaten by the winner.
    public let beatenLengths: Double?
    /// Lengths beaten in total across the race.
    public let overallBeatenLengths: Double?
    public let startingPriceDecimal: Double?
    public let officialRating: Int?
    public let racingPostRating: Int?
    public let topspeedRating: Int?
    public let weightPounds: Int?
    public let jockeyID: String?
    public let comment: String?

    public init(
        raceID: String,
        date: String,
        courseName: String,
        courseID: String? = nil,
        distance: Distance? = nil,
        going: Going = .unknown,
        raceType: RaceType = .unknown,
        raceClass: Int? = nil,
        fieldSize: Int? = nil,
        position: FinishPosition,
        beatenLengths: Double? = nil,
        overallBeatenLengths: Double? = nil,
        startingPriceDecimal: Double? = nil,
        officialRating: Int? = nil,
        racingPostRating: Int? = nil,
        topspeedRating: Int? = nil,
        weightPounds: Int? = nil,
        jockeyID: String? = nil,
        comment: String? = nil
    ) {
        self.raceID = raceID
        self.date = date
        self.courseName = courseName
        self.courseID = courseID
        self.distance = distance
        self.going = going
        self.raceType = raceType
        self.raceClass = raceClass
        self.fieldSize = fieldSize
        self.position = position
        self.beatenLengths = beatenLengths
        self.overallBeatenLengths = overallBeatenLengths
        self.startingPriceDecimal = startingPriceDecimal
        self.officialRating = officialRating
        self.racingPostRating = racingPostRating
        self.topspeedRating = topspeedRating
        self.weightPounds = weightPounds
        self.jockeyID = jockeyID
        self.comment = comment
    }
}
