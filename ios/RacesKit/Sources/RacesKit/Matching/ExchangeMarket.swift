import Foundation

/// The exchange's view of one race, before it has been joined to ours.
///
/// Provider-agnostic on purpose, and deliberately *not* a Betfair DTO: the
/// matcher is pure logic over these fields, so it is tested on Linux against
/// fixtures and does not care which exchange produced them. A Betfair
/// `listMarketCatalogue` entry maps into this; so could anything else.
public struct ExchangeMarket: Hashable, Sendable, Identifiable {
    public let id: String
    /// Betfair `Event.venue` — the course, e.g. `Newmarket`.
    public let venue: String
    /// Betfair `marketStartTime`. The scheduled off, not the actual one.
    public let startTime: Date
    /// Betfair `MarketCatalogue.marketName`, e.g. `2m Hcap Chs`. Not matched on;
    /// carried because it is useful when explaining a refusal.
    public let marketName: String?
    public let runners: [ExchangeRunner]

    public init(
        id: String,
        venue: String,
        startTime: Date,
        marketName: String? = nil,
        runners: [ExchangeRunner]
    ) {
        self.id = id
        self.venue = venue
        self.startTime = startTime
        self.marketName = marketName
        self.runners = runners
    }

    /// Runners still standing. A removed runner is excluded from matching
    /// entirely: it has no price, and counting it would drag the overlap check
    /// down for a race that matched perfectly well.
    public var activeRunners: [ExchangeRunner] {
        runners.filter(\.isActive)
    }
}

/// One selection on the exchange.
public struct ExchangeRunner: Hashable, Sendable, Identifiable {
    /// Betfair `SELECTION_ID`.
    public let id: Int64
    /// As the exchange presents it, decoration included: `3. Kyprios (IRE)`.
    public let name: String
    /// Betfair `CLOTH_NUMBER` metadata. Absent on some markets, and the reason
    /// name matching exists at all.
    public let clothNumber: Int?
    /// Betfair runner status is `ACTIVE`, `REMOVED`, `WINNER` or `LOSER`.
    public let isActive: Bool

    public init(id: Int64, name: String, clothNumber: Int? = nil, isActive: Bool = true) {
        self.id = id
        self.name = name
        self.clothNumber = clothNumber
        self.isActive = isActive
    }
}
