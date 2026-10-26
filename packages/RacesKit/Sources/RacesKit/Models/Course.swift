import Foundation

/// A racecourse. Backs the Courses tab and the join between the two providers'
/// views of the same meeting.
public struct Course: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let regionCode: String
    public let region: String

    public init(id: String, name: String, regionCode: String, region: String) {
        self.id = id
        self.name = name
        self.regionCode = regionCode
        self.region = region
    }

    public var isBritish: Bool { regionCode.lowercased() == "gb" }
}

extension Sequence where Element == Course {
    /// O(1) lookup by id, last wins.
    public var keyedByID: [String: Course] {
        Dictionary(map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public var sortedByName: [Course] {
        sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
