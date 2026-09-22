import Foundation

extension MarketSnapshot {

    /// Build the rater's snapshot from exchange-keyed prices and a
    /// selection→horse map.
    ///
    /// This is the one crossing between the exchange's identifiers and ours, and
    /// it **drops** prices for selections that did not match rather than guessing.
    /// A price attached to the wrong horse looks entirely normal and silently
    /// anchors the model to another animal — the worst thing this layer can do,
    /// and undetectable from the output.
    public init(
        joining prices: ExchangeMarketPrices,
        horseIDsBySelectionID: [Int64: String],
        source: MarketSnapshot.Source = .liveExchange
    ) {
        var byHorse: [String: RunnerPrice] = [:]
        for (selectionID, price) in prices.prices {
            guard let horseID = horseIDsBySelectionID[selectionID] else { continue }
            byHorse[horseID] = price
        }
        self.init(
            marketID: prices.marketID,
            source: source,
            capturedAt: prices.capturedAt,
            isDelayed: prices.isDelayed,
            prices: byHorse)
    }
}

extension RaceMarketMatch {

    /// The snapshot for this match, using the pairings the matcher established.
    ///
    /// Reads from `runners.pairings` rather than being handed a map, so the join
    /// cannot disagree with the match it came from. If the matcher refused a
    /// runner, that runner has no price — which is the correct outcome, and is
    /// what `MarketSnapshot.coverage(of:)` then reports to the rater.
    public func snapshot(
        from prices: ExchangeMarketPrices,
        source: MarketSnapshot.Source = .liveExchange
    ) -> MarketSnapshot {
        var horseIDsBySelectionID: [Int64: String] = [:]
        for pairing in runners.pairings {
            horseIDsBySelectionID[pairing.selectionID] = pairing.horseID
        }
        return MarketSnapshot(
            joining: prices,
            horseIDsBySelectionID: horseIDsBySelectionID,
            source: source)
    }
}
