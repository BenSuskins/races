import Foundation

/// What the user's subscription actually allows.
///
/// This is the free/paid boundary made explicit. It is invisible in the API — you
/// discover it when a 403 comes back — so we detect it once, remember it, and let
/// the rest of the app ask rather than guess.
///
/// It drives two things: which rating factors are available, and what the UI can
/// honestly say about why a tip is thinner than it might be.
public struct ProviderCapability: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Today's and tomorrow's cards. Available on every tier including free.
    public static let racecards = ProviderCapability(rawValue: 1 << 0)
    /// Today's results. Free, but today only — miss a day and it is gone.
    public static let todayResults = ProviderCapability(rawValue: 1 << 1)
    /// Per-horse historical results. **The** upgrade: it is what makes deep form
    /// analysis possible at all.
    public static let formHistory = ProviderCapability(rawValue: 1 << 2)
    /// Racing Post and Topspeed ratings on the racecard.
    public static let expertRatings = ProviderCapability(rawValue: 1 << 3)
    /// Trainer 14-day form on the racecard.
    public static let trainerForm = ProviderCapability(rawValue: 1 << 4)
    /// Historical results across all races, with starting prices.
    public static let historicalResults = ProviderCapability(rawValue: 1 << 5)

    /// What The Racing API's free tier gives.
    public static let free: ProviderCapability = [.racecards, .todayResults]

    /// What their Basic tier adds.
    public static let basic: ProviderCapability = [
        .racecards, .todayResults, .formHistory, .expertRatings, .trainerForm,
    ]

    /// A short, honest sentence for the UI. Never phrased as an error — running on
    /// the free tier is a normal state, not a fault.
    public var summary: String {
        if contains(.formHistory) {
            return "Full form history available."
        }
        return "Form history isn't on your plan — tips use the racecard and the market only."
    }
}
