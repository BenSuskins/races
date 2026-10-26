import Foundation

/// Where a runner's mark sits in today's field.
///
/// An official rating in isolation says nothing: 78 is a good mark in a Class 6
/// handicap and nowhere near enough in a Listed race. What the user can act on is
/// the rank within *this* race, which is also exactly how the rating engine
/// standardises the factor — so showing the raw number alone would be strictly
/// less informative than what the model already computes.
///
/// `nonisolated` because it is pure arithmetic over integers, and because the
/// tests that pin the tie-handling are not main-actor bound.
nonisolated enum RatingContext {

    /// Standard competition ranking, highest first: the number of strictly better
    /// marks, plus one. Two runners on the same mark therefore share a position,
    /// which is the truthful answer — nothing in the data breaks the tie.
    static func rank(_ rating: Int, among ratings: [Int]) -> (position: Int, total: Int)? {
        guard ratings.count > 1, ratings.contains(rating) else { return nil }
        let better = ratings.filter { $0 > rating }.count
        return (position: better + 1, total: ratings.count)
    }

    /// A phrase for the racecard, or nil when there is nothing worth saying.
    static func describe(_ rating: Int, among ratings: [Int]) -> String? {
        guard let (position, total) = rank(rating, among: ratings) else { return nil }
        let sharedMark = ratings.filter { $0 == rating }.count > 1

        if position == 1 {
            return sharedMark
                ? "Joint top-rated of \(total)"
                : "Top-rated of \(total)"
        }
        return "\(ordinal(position)) of \(total) rated"
    }

    static func ordinal(_ value: Int) -> String {
        let suffix: String
        switch (value % 100, value % 10) {
        // 11th, 12th and 13th are the exceptions that make a bare `% 10` wrong.
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(value)\(suffix)"
    }
}
