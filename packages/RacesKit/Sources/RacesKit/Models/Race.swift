import Foundation

/// A race on a card, provider-agnostic.
public struct Race: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let courseName: String
    /// Paid tiers only; the free racecard gives the course by name alone, which is
    /// why `CourseNameNormaliser` has to exist.
    public let courseID: String?
    public let name: String
    /// Local time as printed, e.g. "14:30".
    public let offTime: String
    public let offDateTime: Date?
    /// yyyy-MM-dd, Europe/London.
    public let date: String

    public let distance: Distance?
    public let going: Going
    public let surface: Surface
    public let type: RaceType
    public let raceClass: Int?
    public let pattern: String?
    public let ageBand: String?
    public let ratingBand: ClosedRange<Int>?
    public let prize: String?
    public let fieldSize: Int?
    public let regionCode: String?
    public let status: String?

    public let runners: [Runner]

    public init(
        id: String,
        courseName: String,
        courseID: String? = nil,
        name: String,
        offTime: String,
        offDateTime: Date? = nil,
        date: String,
        distance: Distance? = nil,
        going: Going = .unknown,
        surface: Surface = .unknown,
        type: RaceType = .unknown,
        raceClass: Int? = nil,
        pattern: String? = nil,
        ageBand: String? = nil,
        ratingBand: ClosedRange<Int>? = nil,
        prize: String? = nil,
        fieldSize: Int? = nil,
        regionCode: String? = nil,
        status: String? = nil,
        runners: [Runner] = []
    ) {
        self.id = id
        self.courseName = courseName
        self.courseID = courseID
        self.name = name
        self.offTime = offTime
        self.offDateTime = offDateTime
        self.date = date
        self.distance = distance
        self.going = going
        self.surface = surface
        self.type = type
        self.raceClass = raceClass
        self.pattern = pattern
        self.ageBand = ageBand
        self.ratingBand = ratingBand
        self.prize = prize
        self.fieldSize = fieldSize
        self.regionCode = regionCode
        self.status = status
        self.runners = runners
    }

    /// Whether this is a handicap, inferred from the race title.
    ///
    /// The free tier has no explicit flag, and the distinction matters: in a
    /// handicap the official rating is the handicapper's considered opinion of
    /// every runner on a common scale, which makes it far more informative than in
    /// a conditions race where the weights are set by the conditions instead.
    ///
    /// Inferring from the title is imperfect but reliable in British racing, where
    /// naming a handicap as such is a condition of the race.
    public var isHandicap: Bool {
        let title = name.lowercased()
        return title.contains("handicap") || title.contains("h'cap") || title.contains("hcap")
    }

    /// Runners that are actually taking part, in racecard order.
    public var declaredRunners: [Runner] {
        runners.sorted { lhs, rhs in
            switch (lhs.clothNumber, rhs.clothNumber) {
            case let (l?, r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.name < rhs.name
            }
        }
    }

    /// The number actually declared, which is more trustworthy than the provider's
    /// `field_size` once non-runners start being taken out through the day.
    public var runnerCount: Int { runners.count }

    public var hasStarted: Bool {
        guard let offDateTime else { return false }
        return offDateTime < Date()
    }
}

/// A day's racing at one course. Cards are browsed by meeting, not as a flat list.
public struct Meeting: Identifiable, Hashable, Sendable {
    public let courseName: String
    public let date: String
    public let races: [Race]

    public var id: String { "\(date)|\(courseName)" }

    public init(courseName: String, date: String, races: [Race]) {
        self.courseName = courseName
        self.date = date
        self.races = races.sorted { ($0.offDateTime ?? .distantFuture) < ($1.offDateTime ?? .distantFuture) }
    }

    public var going: Going { races.first?.going ?? .unknown }
    public var surface: Surface { races.first?.surface ?? .unknown }

    /// The next race still to run, for the "what's on now" view.
    public var nextRace: Race? {
        races.first { !$0.hasStarted }
    }
}

extension Sequence where Element == Race {
    /// Group a day's races into meetings, ordered by each meeting's first race.
    public func groupedIntoMeetings() -> [Meeting] {
        Dictionary(grouping: self) { "\($0.date)|\($0.courseName)" }
            .values
            .compactMap { races -> Meeting? in
                guard let first = races.first else { return nil }
                return Meeting(courseName: first.courseName, date: first.date, races: races)
            }
            .sorted { lhs, rhs in
                let l = lhs.races.first?.offDateTime ?? .distantFuture
                let r = rhs.races.first?.offDateTime ?? .distantFuture
                return l == r ? lhs.courseName < rhs.courseName : l < r
            }
    }
}
