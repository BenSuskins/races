import Foundation

/// Betfair wire types → the provider-agnostic models the rest of the kit uses.
///
/// The only place in the app that knows Betfair's JSON shape. Everything
/// downstream — the matcher, the rater, the tracker — sees `ExchangeMarket` and
/// `ExchangeMarketPrices` and cannot tell which exchange produced them.
enum BetfairMapping {

    /// Betfair's runner metadata keys. Every value arrives as a string,
    /// including the numeric ones, which is why `CLOTH_NUMBER` needs parsing
    /// rather than reading.
    enum MetadataKey {
        static let clothNumber = "CLOTH_NUMBER"
        static let jockeyName = "JOCKEY_NAME"
        static let trainerName = "TRAINER_NAME"
        static let form = "FORM"
        static let officialRating = "OFFICIAL_RATING"
        static let stallDraw = "STALL_DRAW"
        static let wearing = "WEARING"
    }

    static func exchangeMarket(from catalogue: BetfairMarketCatalogue) -> ExchangeMarket? {
        // A market with no start time cannot be matched: the ±6 minute window is
        // half the evidence the matcher has. Dropping it is right — a market
        // matched on venue alone would price a race off whatever else is running
        // at that course.
        guard let startTimeText = catalogue.marketStartTime,
              let startTime = RaceDates.parseTimestamp(startTimeText) else { return nil }

        // `venue` is the course. It is on the event, not the market, and it is
        // occasionally absent — in which case the event name is the best
        // available and `CourseNameNormaliser` will do the rest.
        guard let venue = catalogue.event?.venue ?? catalogue.event?.name,
              !venue.isEmpty else { return nil }

        let runners = (catalogue.runners ?? []).map { runner in
            ExchangeRunner(
                id: runner.selectionId,
                name: runner.runnerName ?? "",
                clothNumber: clothNumber(from: runner.metadata),
                isActive: runner.status == nil || runner.status == "ACTIVE")
        }

        return ExchangeMarket(
            id: catalogue.marketId,
            venue: venue,
            startTime: startTime,
            marketName: catalogue.marketName,
            runners: runners)
    }

    /// `CLOTH_NUMBER` as an integer, or nil.
    ///
    /// Arrives as a string, sometimes blank, sometimes `"0"` on a market where
    /// the numbers are not published. Zero is not a cloth number — treating it
    /// as one would have the matcher join on a value every non-runner shares.
    static func clothNumber(from metadata: [String: String]?) -> Int? {
        guard let raw = metadata?[MetadataKey.clothNumber]?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    static func prices(
        from book: BetfairMarketBook,
        capturedAt: Date
    ) -> ExchangeMarketPrices? {
        let prices = (book.runners ?? []).reduce(into: [Int64: RunnerPrice]()) { result, runner in
            result[runner.selectionId] = RunnerPrice(
                backPrice: runner.bestBack,
                layPrice: runner.bestLay,
                lastTraded: runner.lastPriceTraded,
                // `nearPrice` is the exchange's projected SP and is the only
                // anchor a tomorrow market has: those have next to no
                // liquidity, so back and lay are frequently both absent.
                forecastPrice: runner.sp?.nearPrice,
                isActive: runner.isActive)
        }
        guard !prices.isEmpty else { return nil }

        return ExchangeMarketPrices(
            marketID: book.marketId,
            status: book.status,
            capturedAt: capturedAt,
            // Trust the exchange's own flag when it sets one. The free key is
            // always delayed, so absent means assume delayed rather than live —
            // claiming live prices we do not have is the worse error.
            isDelayed: book.isMarketDataDelayed ?? true,
            prices: prices)
    }

    /// Join exchange prices to our runners, producing the snapshot the rater
    /// takes.
    ///
    /// Takes the selection→horse map the matcher produced. Prices for
    /// selections that did not match are dropped rather than guessed at: a
    /// price attached to the wrong horse is the single worst thing this layer
    /// could do, and it would look entirely normal.
    static func snapshot(
        from prices: ExchangeMarketPrices,
        horseIDsBySelectionID: [Int64: String],
        source: MarketSnapshot.Source = .liveExchange
    ) -> MarketSnapshot {
        // One implementation of the crossing, in the matching layer where it
        // belongs — it is not Betfair-specific, and two copies could drift.
        MarketSnapshot(
            joining: prices,
            horseIDsBySelectionID: horseIDsBySelectionID,
            source: source)
    }
}
