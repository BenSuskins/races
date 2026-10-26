import Foundation

/// Where a race sits on the exchange, kept so a settled starting price can be
/// looked up long after the race has run.
///
/// This is the one place exchange identifiers are deliberately **persisted**.
/// `MarketSnapshot` drops them on purpose — the rater must not know two
/// providers exist — but settlement is a different job: Betfair returns starting
/// prices keyed by its own selection id, and hours or days later the catalogue
/// that would let us re-derive the mapping may be gone. So the mapping is frozen
/// with the tip, at the moment the match was made and believed.
///
/// Keyed **our id → their id**, not the reverse, for a mundane but load-bearing
/// reason: `[String: Int64]` is a JSON object, while `[Int64: Double]` encodes as
/// a flat alternating array. The stored ledger stays readable by a human, which
/// matters for a file that is the only copy of the accuracy record.
public struct MarketReference: Codable, Hashable, Sendable {

    public let marketID: String
    /// Every runner the matcher paired, not just the selection.
    ///
    /// The whole map rather than one selection id, because the favourite
    /// baseline needs a price too — and that is the number the tracker exists to
    /// be compared against. Storing only the tip's own selection would leave the
    /// benchmark permanently priceless while the tip had a price, which is the
    /// most flattering possible asymmetry.
    public let selectionIDsByHorseID: [String: Int64]

    public init(marketID: String, selectionIDsByHorseID: [String: Int64]) {
        self.marketID = marketID
        self.selectionIDsByHorseID = selectionIDsByHorseID
    }

    public func selectionID(forHorse horseID: String) -> Int64? {
        selectionIDsByHorseID[horseID]
    }

    /// Re-key Betfair's settled starting prices onto our horse ids.
    ///
    /// Takes the whole `[marketID: [selectionID: price]]` reply so a caller can
    /// hand over one batch for every tip rather than slicing it per race.
    ///
    /// **Drops** anything it cannot place, exactly as the price join does: a
    /// starting price attributed to the wrong horse would inflate or destroy an
    /// ROI figure with nothing on screen to suggest it had happened.
    public func startingPrices(
        from settled: [String: [Int64: Double]]
    ) -> [String: Double] {
        guard let bySelection = settled[marketID] else { return [:] }

        var byHorse: [String: Double] = [:]
        for (horseID, selectionID) in selectionIDsByHorseID {
            guard let price = bySelection[selectionID], price > 1 else { continue }
            byHorse[horseID] = price
        }
        return byHorse
    }
}

extension RaceMarketMatch {

    /// The settlement coordinates for this match.
    ///
    /// Built from `runners.pairings`, so it cannot disagree with the match that
    /// produced it — the same reason `snapshot(from:)` reads the pairings rather
    /// than taking a map.
    public func reference() -> MarketReference {
        var selectionIDs: [String: Int64] = [:]
        for pairing in runners.pairings {
            selectionIDs[pairing.horseID] = pairing.selectionID
        }
        return MarketReference(marketID: marketID, selectionIDsByHorseID: selectionIDs)
    }
}
