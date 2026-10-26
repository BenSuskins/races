import Foundation
@testable import RacesKit

/// Builders for matching tests. Separate from `TestRace` because these need
/// course names and real off times, which the rating tests have no use for.
enum TestMatching {

    /// 2026-09-21 14:30 in London (BST, so 13:30 UTC), as a fixed instant.
    ///
    /// Fixed rather than relative to `now` so these tests cannot drift into
    /// passing or failing with the clock. It agrees with the `offTime: "14:30"`
    /// the builders below use, which matters only to a reader — nothing in the
    /// matcher reads the printed time.
    static let baseOff: Date = Date(timeIntervalSince1970: 1_789_997_400)

    static func at(_ minutesFromBase: Double) -> Date {
        baseOff.addingTimeInterval(minutesFromBase * 60)
    }

    static func race(
        id: String = "rac_1",
        course: String = "Newmarket",
        offAt: Date? = baseOff,
        horses: [String]
    ) -> Race {
        Race(
            id: id,
            courseName: course,
            name: "Test Handicap",
            offTime: "14:30",
            offDateTime: offAt,
            date: "2026-09-21",
            fieldSize: horses.count,
            runners: horses.enumerated().map { index, name in
                Runner(id: "hrs_\(id)_\(index + 1)", name: name, clothNumber: index + 1)
            }
        )
    }

    /// A race whose cloth numbers are given explicitly, for the disagreement cases.
    static func race(
        id: String = "rac_1",
        course: String = "Newmarket",
        offAt: Date? = baseOff,
        numbered: [(String, Int?)]
    ) -> Race {
        Race(
            id: id,
            courseName: course,
            name: "Test Handicap",
            offTime: "14:30",
            offDateTime: offAt,
            date: "2026-09-21",
            fieldSize: numbered.count,
            runners: numbered.enumerated().map { index, entry in
                Runner(id: "hrs_\(id)_\(index + 1)", name: entry.0, clothNumber: entry.1)
            }
        )
    }

    static func market(
        id: String = "1.100",
        venue: String = "Newmarket",
        startAt: Date = baseOff,
        selections: [String]
    ) -> ExchangeMarket {
        ExchangeMarket(
            id: id,
            venue: venue,
            startTime: startAt,
            marketName: "1m Hcap",
            runners: selections.enumerated().map { index, name in
                ExchangeRunner(
                    id: Int64(10_000 + index + 1), name: name, clothNumber: index + 1)
            }
        )
    }

    /// A market whose selections carry explicit cloth numbers and status.
    static func market(
        id: String = "1.100",
        venue: String = "Newmarket",
        startAt: Date = baseOff,
        detailed: [(name: String, cloth: Int?, active: Bool)]
    ) -> ExchangeMarket {
        ExchangeMarket(
            id: id,
            venue: venue,
            startTime: startAt,
            marketName: "1m Hcap",
            runners: detailed.enumerated().map { index, entry in
                ExchangeRunner(
                    id: Int64(10_000 + index + 1),
                    name: entry.name,
                    clothNumber: entry.cloth,
                    isActive: entry.active)
            }
        )
    }
}
