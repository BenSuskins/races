import Foundation

/// Prices for one runner, as the exchange sees them.
public struct RunnerPrice: Codable, Hashable, Sendable {
    /// Best price available to back, decimal.
    public let backPrice: Double?
    /// Best price available to lay, decimal.
    public let layPrice: Double?
    public let lastTraded: Double?
    /// The bookmakers' forecast price. Matters more than it looks: tomorrow's
    /// markets have little or no liquidity, so this is often the only anchor
    /// available for a card that has not started trading.
    public let forecastPrice: Double?
    /// False once a runner is withdrawn. Removed runners must be excluded from the
    /// book entirely rather than de-vigged along with the rest.
    public let isActive: Bool

    public init(
        backPrice: Double? = nil,
        layPrice: Double? = nil,
        lastTraded: Double? = nil,
        forecastPrice: Double? = nil,
        isActive: Bool = true
    ) {
        self.backPrice = backPrice
        self.layPrice = layPrice
        self.lastTraded = lastTraded
        self.forecastPrice = forecastPrice
        self.isActive = isActive
    }

    public var hasAnyPrice: Bool {
        backPrice != nil || layPrice != nil || lastTraded != nil || forecastPrice != nil
    }
}

/// The market's view of one race at a moment in time.
///
/// Keyed by *our* horse id, not the exchange's selection id: matching happens
/// before this type is built, so the rating engine never has to know that two
/// providers exist.
public struct MarketSnapshot: Codable, Hashable, Sendable {

    /// Where the prices came from. Surfaced in the UI, because "live exchange,
    /// delayed three minutes" and "bookmakers' forecast" deserve different trust.
    public enum Source: String, Codable, Sendable {
        case liveExchange
        case forecast

        public var displayName: String {
            switch self {
            case .liveExchange: return "Exchange prices"
            case .forecast: return "Forecast prices"
            }
        }
    }

    public let marketID: String?
    public let source: Source
    public let capturedAt: Date
    /// The free Betfair app key returns prices delayed by 1–180 seconds. Fine for
    /// ranking runners; worth saying out loud wherever a price is shown.
    public let isDelayed: Bool
    public let prices: [String: RunnerPrice]
    public let firstObservedAt: Date?
    public let firstObservedPrices: [String: RunnerPrice]?

    public init(
        marketID: String? = nil,
        source: Source = .liveExchange,
        capturedAt: Date = Date(),
        isDelayed: Bool = true,
        prices: [String: RunnerPrice],
        firstObservedAt: Date? = nil,
        firstObservedPrices: [String: RunnerPrice]? = nil
    ) {
        self.marketID = marketID
        self.source = source
        self.capturedAt = capturedAt
        self.isDelayed = isDelayed
        self.prices = prices
        self.firstObservedAt = firstObservedAt
        self.firstObservedPrices = firstObservedPrices
    }

    public func price(for horseID: String) -> RunnerPrice? {
        prices[horseID]
    }

    /// The share of a field we actually have a usable price for.
    ///
    /// Below the rater's threshold the market is discarded wholesale rather than
    /// used to anchor part of a race: a book missing three runners is not a book,
    /// and de-vigging what remains would quietly inflate everyone else.
    public func coverage(of runners: [Runner]) -> Double {
        guard !runners.isEmpty else { return 0 }
        let priced = runners.filter { price(for: $0.id)?.hasAnyPrice == true }
        return Double(priced.count) / Double(runners.count)
    }
}
