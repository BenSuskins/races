import Foundation

/// One horse declared in a race, as the app understands it — provider-agnostic,
/// so the Racing API and Betfair both map into this shape.
///
/// Almost everything is optional, and deliberately so. On the free data tier a
/// great deal is simply absent: an unraced two-year-old has no official rating and
/// no form, a jumps runner has no draw. `nil` here means *unknown*, never zero —
/// the rating engine treats those as race-neutral rather than as the worst in the
/// field, and conflating them would quietly libel every first-time runner.
public struct Runner: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public let clothNumber: Int?
    public let draw: Int?
    public let age: Int?
    public let sex: String?
    public let regionCode: String?

    /// The handicapper's mark. The strongest single factor available for free.
    public let officialRating: Int?
    /// Weight carried, in pounds.
    public let weightPounds: Int?
    /// Raw headgear code: "b" blinkers, "v" visor, "p" cheekpieces, "t" tongue tie,
    /// "h" hood, "e" eyeshield. May combine, e.g. "bt".
    public let headgear: String?
    /// Recent finishing positions, oldest first — the RIGHTMOST character is the
    /// most recent run. See `FormLine` for parsing.
    public let form: String?
    public let daysSinceLastRun: Int?

    public let jockeyID: String?
    public let jockeyName: String?
    public let trainerID: String?
    public let trainerName: String?
    public let ownerName: String?

    public let sireName: String?
    public let damName: String?

    // MARK: Paid-tier extras — always nil on the free tier.

    /// Racing Post Rating.
    public let racingPostRating: Int?
    /// Topspeed rating.
    public let topspeedRating: Int?
    /// The provider's prose comment on the runner's chance.
    public let spotlight: String?
    public let silkURL: String?

    public init(
        id: String,
        name: String,
        clothNumber: Int? = nil,
        draw: Int? = nil,
        age: Int? = nil,
        sex: String? = nil,
        regionCode: String? = nil,
        officialRating: Int? = nil,
        weightPounds: Int? = nil,
        headgear: String? = nil,
        form: String? = nil,
        daysSinceLastRun: Int? = nil,
        jockeyID: String? = nil,
        jockeyName: String? = nil,
        trainerID: String? = nil,
        trainerName: String? = nil,
        ownerName: String? = nil,
        sireName: String? = nil,
        damName: String? = nil,
        racingPostRating: Int? = nil,
        topspeedRating: Int? = nil,
        spotlight: String? = nil,
        silkURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.clothNumber = clothNumber
        self.draw = draw
        self.age = age
        self.sex = sex
        self.regionCode = regionCode
        self.officialRating = officialRating
        self.weightPounds = weightPounds
        self.headgear = headgear
        self.form = form
        self.daysSinceLastRun = daysSinceLastRun
        self.jockeyID = jockeyID
        self.jockeyName = jockeyName
        self.trainerID = trainerID
        self.trainerName = trainerName
        self.ownerName = ownerName
        self.sireName = sireName
        self.damName = damName
        self.racingPostRating = racingPostRating
        self.topspeedRating = topspeedRating
        self.spotlight = spotlight
        self.silkURL = silkURL
    }

    /// Whether the horse is wearing any headgear today. Note this is NOT the
    /// predictive "first-time headgear" angle, which needs a headgear history the
    /// free tier does not provide.
    public var wearsHeadgear: Bool {
        guard let headgear else { return false }
        return !headgear.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Weight in the stones-and-pounds form a racecard prints, e.g. "9-07".
    public var weightDisplay: String? {
        guard let weightPounds, weightPounds > 0 else { return nil }
        return String(format: "%d-%02d", weightPounds / 14, weightPounds % 14)
    }
}
