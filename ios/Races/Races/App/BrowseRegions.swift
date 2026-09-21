import Foundation

/// Which regions the browse screens ask for.
///
/// Irish racing is included because it appears on British cards and terrestrial
/// coverage all season, and because the matching layer already normalises Irish
/// course names. Narrowing to Britain alone is a one-line change here and nowhere
/// else.
nonisolated enum BrowseRegions {
    static let codes = ["gb", "ire"]
}
