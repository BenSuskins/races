import Foundation

// Wire types for The Racing API's free tier, kept deliberately dumb: they mirror
// the payload exactly and do no interpretation. All translation happens in
// `RacingAPIMapping`, so a provider change touches one layer rather than leaking
// into the domain models.
//
// Property names are camelCase equivalents of the snake_case wire keys; the
// client's decoder uses `.convertFromSnakeCase`, which keeps ~60 hand-written
// CodingKeys out of the codebase and out of the ways it can go wrong.
//
// Every numeric field is `LenientNumber?`. That is not belt-and-braces: The
// Racing API's own OpenAPI spec declares `ofr`, `lbs`, `draw`, `number` and
// `last_run` as `type: string`, so they genuinely arrive quoted.

// MARK: - Courses

struct RacingAPICoursesPage: Decodable {
    let courses: [RacingAPICourse]?
}

struct RacingAPICourse: Decodable {
    let id: String?
    let course: String?
    let regionCode: String?
    let region: String?
}

// MARK: - Racecards

struct RacingAPIRacecardsPage: Decodable {
    let racecards: [RacingAPIRacecard]?
}

struct RacingAPIRacecard: Decodable {
    let raceId: String?
    let course: String?
    let courseId: String?
    let date: String?
    let offTime: String?
    let offDt: String?
    let raceName: String?
    let distanceF: LenientNumber?
    let region: String?
    let pattern: String?
    let raceClass: String?
    let type: String?
    let ageBand: String?
    let ratingBand: String?
    let sexRestriction: String?
    let prize: String?
    let fieldSize: LenientNumber?
    let going: String?
    let surface: String?
    let raceStatus: String?
    let runners: [RacingAPIRunner]?
}

struct RacingAPIRunner: Decodable {
    let horseId: String?
    let horse: String?
    let age: LenientNumber?
    let sex: String?
    let colour: String?
    let region: String?
    let number: LenientNumber?
    let draw: LenientNumber?
    let headgear: String?
    let lbs: LenientNumber?
    let ofr: LenientNumber?
    let lastRun: LenientNumber?
    let form: String?
    let jockey: String?
    let jockeyId: String?
    let trainer: String?
    let trainerId: String?
    let owner: String?
    let ownerId: String?
    let sire: String?
    let dam: String?

    // Present on paid tiers only; absent from the free payload.
    let rpr: LenientNumber?
    let ts: LenientNumber?
    let spotlight: String?
    let silkUrl: String?
}

// MARK: - Results

struct RacingAPIResultsPage: Decodable {
    let results: [RacingAPIResult]?
}

struct RacingAPIResult: Decodable {
    let raceId: String?
    let course: String?
    let courseId: String?
    let date: String?
    let offDt: String?
    let raceName: String?
    let distF: LenientNumber?
    let region: String?
    let pattern: String?
    // `class` is a Swift keyword, so it is spelled with backticks here rather
    // than renamed — the wire key has to match.
    let `class`: String?
    let type: String?
    let ageBand: String?
    let ratingBand: String?
    let going: String?
    let surface: String?
    let runners: [RacingAPIResultRunner]?
}

struct RacingAPIResultRunner: Decodable {
    let horseId: String?
    let horse: String?
    let position: String?
    let number: LenientNumber?
    let draw: LenientNumber?
    let weightLbs: LenientNumber?
    let `or`: LenientNumber?
    let jockey: String?
    let jockeyId: String?
    let trainer: String?
    let trainerId: String?

    // Paid tiers only. These are what make a past run interpretable: how far the
    // horse was beaten, what it was rated, and what price it went off at.
    let spDec: LenientNumber?
    let btn: LenientNumber?
    let ovrBtn: LenientNumber?
    let rpr: LenientNumber?
    let tsr: LenientNumber?
    let comment: String?
}
