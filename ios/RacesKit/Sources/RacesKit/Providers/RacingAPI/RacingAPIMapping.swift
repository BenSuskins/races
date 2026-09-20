import Foundation

/// Translates The Racing API's wire types into the app's domain models.
///
/// All the coercion lives here, on purpose. The DTOs stay a faithful mirror of the
/// payload and the domain models stay clean, so when the provider changes a field
/// there is exactly one place to look.
///
/// The governing rule: **a value we cannot trust becomes `nil`, never a default.**
/// A horse with no official rating is unknown, not rated zero. The rating engine
/// treats unknown as race-neutral; zero would make it the worst horse in the race.
enum RacingAPIMapping {

    // MARK: - Courses

    static func course(from dto: RacingAPICourse) -> Course? {
        guard let id = nonEmpty(dto.id), let name = nonEmpty(dto.course) else { return nil }
        return Course(
            id: id,
            name: name,
            regionCode: nonEmpty(dto.regionCode)?.lowercased() ?? "",
            region: nonEmpty(dto.region) ?? ""
        )
    }

    // MARK: - Racecards

    static func race(from dto: RacingAPIRacecard) -> Race? {
        // A race with no id cannot be cached, matched, or reconciled against a
        // result, so it is worth nothing to us. Everything else can be missing.
        guard let id = nonEmpty(dto.raceId) else { return nil }

        let date = nonEmpty(dto.date) ?? RaceDates.dayString()
        let offTime = nonEmpty(dto.offTime) ?? ""

        return Race(
            id: id,
            courseName: nonEmpty(dto.course) ?? "Unknown course",
            courseID: nonEmpty(dto.courseId),
            name: nonEmpty(dto.raceName) ?? "Race",
            offTime: offTime,
            offDateTime: RaceDates.parseTimestamp(dto.offDt)
                ?? RaceDates.combine(date: date, offTime: offTime),
            date: date,
            distance: Distance(furlongs: dto.distanceF?.double),
            going: Going(raw: dto.going),
            surface: Surface(raw: dto.surface),
            type: RaceType(raw: dto.type),
            raceClass: raceClass(from: dto.raceClass),
            pattern: nonEmpty(dto.pattern),
            ageBand: nonEmpty(dto.ageBand),
            ratingBand: ratingBand(from: dto.ratingBand),
            prize: nonEmpty(dto.prize),
            fieldSize: dto.fieldSize?.int,
            regionCode: nonEmpty(dto.region)?.lowercased(),
            status: nonEmpty(dto.raceStatus),
            runners: (dto.runners ?? []).compactMap(runner(from:))
        )
    }

    static func runner(from dto: RacingAPIRunner) -> Runner? {
        guard let id = nonEmpty(dto.horseId), let name = nonEmpty(dto.horse) else { return nil }
        return Runner(
            id: id,
            name: name,
            clothNumber: dto.number?.int,
            draw: dto.draw?.int,
            age: dto.age?.int,
            sex: nonEmpty(dto.sex),
            regionCode: nonEmpty(dto.region),
            officialRating: dto.ofr?.int,
            weightPounds: dto.lbs?.int,
            headgear: nonEmpty(dto.headgear),
            form: nonEmpty(dto.form),
            daysSinceLastRun: dto.lastRun?.int,
            jockeyID: nonEmpty(dto.jockeyId),
            jockeyName: nonEmpty(dto.jockey),
            trainerID: nonEmpty(dto.trainerId),
            trainerName: nonEmpty(dto.trainer),
            ownerName: nonEmpty(dto.owner),
            sireName: nonEmpty(dto.sire),
            damName: nonEmpty(dto.dam),
            racingPostRating: dto.rpr?.int,
            topspeedRating: dto.ts?.int,
            spotlight: nonEmpty(dto.spotlight),
            silkURL: nonEmpty(dto.silkUrl)
        )
    }

    // MARK: - Results

    static func result(from dto: RacingAPIResult) -> RaceResult? {
        guard let id = nonEmpty(dto.raceId) else { return nil }
        return RaceResult(
            id: id,
            courseName: nonEmpty(dto.course) ?? "Unknown course",
            name: nonEmpty(dto.raceName) ?? "Race",
            date: nonEmpty(dto.date) ?? RaceDates.dayString(),
            offDateTime: RaceDates.parseTimestamp(dto.offDt),
            distance: Distance(furlongs: dto.distF?.double),
            going: Going(raw: dto.going),
            surface: Surface(raw: dto.surface),
            type: RaceType(raw: dto.type),
            raceClass: raceClass(from: dto.`class`?.value),
            finishers: (dto.runners ?? []).compactMap(finisher(from:))
        )
    }

    static func finisher(from dto: RacingAPIResultRunner) -> Finisher? {
        guard let horseID = nonEmpty(dto.horseId) else { return nil }
        return Finisher(
            horseID: horseID,
            horseName: nonEmpty(dto.horse) ?? "Unknown",
            position: FinishPosition(raw: dto.position?.value),
            clothNumber: dto.number?.int,
            draw: dto.draw?.int,
            weightPounds: dto.weightLbs?.int,
            officialRating: dto.or?.int,
            jockeyID: nonEmpty(dto.jockeyId),
            trainerID: nonEmpty(dto.trainerId),
            startingPriceDecimal: dto.spDec?.double
        )
    }

    // MARK: - Form history (paid tiers)

    /// Pull one horse's run out of a settled race.
    ///
    /// This is the shape the free tier cannot give us, and the reason the paid
    /// upgrade is worth considering: unlike a form-string character, a `HorseRun`
    /// knows the going, the trip, the class, the field size and the beaten
    /// margin — everything needed to tell a Class 7 seller from a Group 1.
    static func horseRun(from dto: RacingAPIResult, horseID: String) -> HorseRun? {
        guard let raceID = nonEmpty(dto.raceId),
              let runner = dto.runners?.first(where: { nonEmpty($0.horseId) == horseID })
        else { return nil }

        return HorseRun(
            raceID: raceID,
            date: nonEmpty(dto.date) ?? "",
            courseName: nonEmpty(dto.course) ?? "Unknown course",
            courseID: nonEmpty(dto.courseId),
            distance: Distance(furlongs: dto.distF?.double),
            going: Going(raw: dto.going),
            raceType: RaceType(raw: dto.type),
            raceClass: raceClass(from: dto.`class`?.value),
            fieldSize: dto.runners?.count,
            position: FinishPosition(raw: runner.position?.value),
            beatenLengths: runner.btn?.double,
            overallBeatenLengths: runner.ovrBtn?.double,
            startingPriceDecimal: runner.spDec?.double,
            officialRating: runner.or?.int,
            racingPostRating: runner.rpr?.int,
            topspeedRating: runner.tsr?.int,
            weightPounds: runner.weightLbs?.int,
            jockeyID: nonEmpty(runner.jockeyId),
            comment: nonEmpty(runner.comment)
        )
    }

    // MARK: - Field helpers

    /// A trimmed string, or nil when it is empty or a placeholder. Providers blank
    /// fields as readily as they omit them, and `""` is not a course name.
    static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "-" else { return nil }
        return trimmed
    }

    /// Race class from "Class 4", "4", or "class4". Anything unrecognised is nil
    /// rather than a guess.
    static func raceClass(from raw: String?) -> Int? {
        guard let raw = nonEmpty(raw) else { return nil }
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty, let value = Int(digits), (1...7).contains(value) else { return nil }
        return value
    }

    /// Rating band from "0-85", "76-95". Used to place a runner's official rating
    /// within the range the race is framed for — a 95 in a 0-95 handicap is at the
    /// top of the weights, the same mark in a 0-110 is not.
    static func ratingBand(from raw: String?) -> ClosedRange<Int>? {
        guard let raw = nonEmpty(raw) else { return nil }
        let parts = raw.split(separator: "-", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2,
              let lower = Int(parts[0]),
              let upper = Int(parts[1]),
              lower <= upper else { return nil }
        return lower...upper
    }
}
