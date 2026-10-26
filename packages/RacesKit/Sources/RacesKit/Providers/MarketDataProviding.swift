import Foundation

/// Prices for one exchange market, keyed by the exchange's own selection id.
///
/// Deliberately **not** `MarketSnapshot`. That type is keyed by *our* horse id
/// and can only be built after matching has joined the two providers' views of a
/// race. Handing the rater exchange-keyed prices directly would mean it had to
/// know two providers exist, which is the thing the matching layer exists to
/// prevent.
public struct ExchangeMarketPrices: Hashable, Sendable, Identifiable {
    public let marketID: String
    /// `OPEN`, `SUSPENDED` or `CLOSED` as the exchange reports it. A suspended
    /// market's prices are stale by definition, so the caller gets to decide
    /// rather than being handed numbers that look live.
    public let status: String?
    public let capturedAt: Date
    /// True for the free delayed app key, which is what this app uses.
    public let isDelayed: Bool
    public let prices: [Int64: RunnerPrice]

    public var id: String { marketID }

    public init(
        marketID: String,
        status: String? = nil,
        capturedAt: Date = Date(),
        isDelayed: Bool = true,
        prices: [Int64: RunnerPrice]
    ) {
        self.marketID = marketID
        self.status = status
        self.capturedAt = capturedAt
        self.isDelayed = isDelayed
        self.prices = prices
    }

    public var isOpen: Bool { status == nil || status == "OPEN" }
}

/// The market side of the world: what the exchange thinks a race is worth.
///
/// Separate from `RacingDataProviding` because either can be absent
/// independently — the user may not have configured Betfair at all, or a race
/// may fail to match. Both are ordinary states the app is built to work in, so
/// neither should be able to break the other.
public protocol MarketDataProviding: AnyObject, Sendable {

    /// Today's or tomorrow's win markets, with the per-runner metadata the
    /// matcher joins on.
    func markets(day: RaceDay, countries: [String]) async throws -> [ExchangeMarket]

    /// Current prices for the given markets.
    ///
    /// The implementation is expected to batch: Betfair caps `listMarketBook` at
    /// 40 market ids per call, and that is a hard limit rather than a guideline.
    func prices(marketIDs: [String]) async throws -> [ExchangeMarketPrices]

    /// Betfair starting price per selection, once a market has settled.
    ///
    /// `[marketID: [selectionID: bsp]]`. This is what turns the tracker's strike
    /// rate into ROI to level stakes, and it is the one number the free Racing
    /// API tier cannot supply at all.
    func startingPrices(marketIDs: [String]) async throws -> [String: [Int64: Double]]
}

extension MarketDataProviding {
    public func markets(day: RaceDay) async throws -> [ExchangeMarket] {
        try await markets(day: day, countries: ["GB", "IE"])
    }
}
