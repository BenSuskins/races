import Foundation

/// Betfair Exchange, read-only.
///
/// This app never places a bet and never will: it uses the free **delayed** app
/// key, which runs against the live exchange with prices 1–180 seconds behind.
/// That is fine for ranking runners and is why the £499 live-key activation fee
/// does not apply.
public actor BetfairClient: MarketDataProviding {

    public static let bettingBaseURL = URL(string: "https://api.betfair.com/exchange/betting/rest/v1.0")!
    /// Betfair is generous compared with the Racing API, but weight-limited.
    /// Conservative because one card refresh fans out into a dozen calls.
    public static let requestsPerSecond: Double = 5.0

    /// **A hard cap, not a guideline.** `listMarketBook` refuses more than this
    /// many market ids per call.
    public static let maximumMarketsPerBook = 40

    /// Horse Racing.
    public static let horseRacingEventTypeID = "7"

    private let session: BetfairSession
    private let credentials: BetfairCredentials
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    public init(
        credentials: BetfairCredentials,
        session: BetfairSession,
        transport: any HTTPPerforming,
        baseURL: URL = BetfairClient.bettingBaseURL,
        requestsPerSecond: Double = BetfairClient.requestsPerSecond,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.session = session
        self.now = now
        self.http = HTTPClient(
            baseURL: baseURL,
            transport: transport,
            requestsPerSecond: requestsPerSecond,
            retryPolicy: .default
        )
    }

    /// Builds a client and its session from one set of credentials.
    public static func make(
        credentials: BetfairCredentials,
        transport: any HTTPPerforming,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> BetfairClient {
        BetfairClient(
            credentials: credentials,
            session: BetfairSession(credentials: credentials, transport: transport, now: now),
            transport: transport,
            now: now
        )
    }

    // MARK: - Markets

    public func markets(day: RaceDay, countries: [String]) async throws -> [ExchangeMarket] {
        let window = BetfairClient.window(for: day, now: now())
        let request = BetfairCatalogueRequest(
            filter: BetfairMarketFilter(
                eventTypeIds: [Self.horseRacingEventTypeID],
                marketCountries: countries,
                marketTypeCodes: ["WIN"],
                marketStartTime: BetfairTimeRange(
                    from: RaceDates.iso8601.string(from: window.from),
                    to: RaceDates.iso8601.string(from: window.to))
            ),
            // RUNNER_METADATA carries CLOTH_NUMBER, which is the join key.
            // Without it the matcher has only names to work with.
            marketProjection: ["RUNNER_METADATA", "MARKET_START_TIME", "EVENT"],
            // Required by the API and capped. A British and Irish card is well
            // under this even on a Saturday.
            maxResults: 200,
            sort: "FIRST_TO_START"
        )

        let catalogues: [BetfairMarketCatalogue] = try await send(
            "/listMarketCatalogue/", body: request)
        return catalogues.compactMap(BetfairMapping.exchangeMarket(from:))
    }

    // MARK: - Prices

    public func prices(marketIDs: [String]) async throws -> [ExchangeMarketPrices] {
        try await books(
            marketIDs: marketIDs,
            priceData: ["EX_BEST_OFFERS"]
        ).compactMap { BetfairMapping.prices(from: $0, capturedAt: now()) }
    }

    public func startingPrices(marketIDs: [String]) async throws -> [String: [Int64: Double]] {
        let books = try await books(marketIDs: marketIDs, priceData: ["SP_TRADED"])
        var result: [String: [Int64: Double]] = [:]
        for book in books {
            let settled = (book.runners ?? []).reduce(into: [Int64: Double]()) { prices, runner in
                // `actualSP` appears only once the market has settled. A nil
                // here is an unsettled race, not a missing price, so it is
                // omitted rather than defaulted — a zero would read as a
                // starting price of evens-ish and wreck the ROI figure.
                if let sp = runner.sp?.actualSP, sp > 0 {
                    prices[runner.selectionId] = sp
                }
            }
            if !settled.isEmpty { result[book.marketId] = settled }
        }
        return result
    }

    /// Fetch books, batching at the API's cap and splitting further if Betfair
    /// says the batch is still too big.
    private func books(
        marketIDs: [String],
        priceData: [String]
    ) async throws -> [BetfairMarketBook] {
        let unique = Array(Set(marketIDs)).sorted()
        guard !unique.isEmpty else { return [] }

        var books: [BetfairMarketBook] = []
        for batch in unique.chunked(into: Self.maximumMarketsPerBook) {
            books += try await booksSplittingOnOversize(batch, priceData: priceData)
        }
        return books
    }

    /// `TOO_MUCH_DATA` is an instruction, not a failure: the same markets will
    /// come back if asked for in smaller groups. Halving recursively costs one
    /// extra round trip per level and is the difference between a card with
    /// prices and a card without.
    private func booksSplittingOnOversize(
        _ marketIDs: [String],
        priceData: [String]
    ) async throws -> [BetfairMarketBook] {
        do {
            let request = BetfairBookRequest(
                marketIds: marketIDs,
                priceProjection: BetfairPriceProjection(priceData: priceData, virtualise: false))
            return try await send("/listMarketBook/", body: request, passingOversize: true)
        } catch let fault as BetfairFault where fault.code == .tooMuchData && marketIDs.count > 1 {
            let middle = marketIDs.count / 2
            let left = try await booksSplittingOnOversize(
                Array(marketIDs[..<middle]), priceData: priceData)
            let right = try await booksSplittingOnOversize(
                Array(marketIDs[middle...]), priceData: priceData)
            return left + right
        } catch let fault as BetfairFault {
            // A single market still too big: nothing left to split.
            throw fault.code.asAPIError
        }
    }

    // MARK: - Transport

    /// One authenticated call, re-authenticating once if the session has lapsed.
    ///
    /// The retry is deliberately single and deliberately only for an invalid
    /// session: anything else that loops here would hammer the exchange.
    ///
    /// Every fault leaves as an `APIError`, except that `passingOversize` lets
    /// `TOO_MUCH_DATA` out as the raw `BetfairFault`. The book splitter needs to
    /// see it to halve the batch; mapped first, it arrived as a `badRequest` the
    /// splitter's catch could never match, so no batch was ever split.
    private func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        body: Body,
        passingOversize: Bool = false
    ) async throws -> [Response] {
        do {
            return try await sendOnce(path, body: body)
        } catch let fault as BetfairFault {
            if passingOversize && fault.code == .tooMuchData { throw fault }
            guard fault.code.isRecoverableBySigningInAgain else {
                throw fault.code.asAPIError
            }
            await session.invalidate()
            return try await sendMappingFaults(path, body: body, passingOversize: passingOversize)
        }
    }

    /// One more attempt, with any fault turned into an `APIError`. Split out so
    /// each function has a single, plainly exhaustive do/catch.
    private func sendMappingFaults<Response: Decodable, Body: Encodable>(
        _ path: String,
        body: Body,
        passingOversize: Bool
    ) async throws -> [Response] {
        do {
            return try await sendOnce(path, body: body)
        } catch let fault as BetfairFault {
            if passingOversize && fault.code == .tooMuchData { throw fault }
            throw fault.code.asAPIError
        }
    }

    private func sendOnce<Response: Decodable, Body: Encodable>(
        _ path: String,
        body: Body
    ) async throws -> [Response] {
        let token = try await session.token()
        let raw: BetfairRawResponse<Response> = try await http.post(
            path,
            json: body,
            authorization: .headers([
                "X-Application": credentials.appKey,
                "X-Authentication": token,
                "Accept": "application/json",
            ])
        )
        switch raw {
        case .success(let values):
            return values
        case .fault(let fault):
            throw fault
        }
    }

    // MARK: - Helpers

    /// The London day the exchange should be asked about.
    ///
    /// A racing day is a Europe/London day, and the exchange wants UTC
    /// instants — so this is exactly the boundary where a naive `Date()`
    /// arithmetic bug puts an evening meeting on the wrong card.
    static func window(for day: RaceDay, now: Date) -> (from: Date, to: Date) {
        let calendar = RaceDates.londonCalendar
        let base: Date
        switch day {
        case .today:
            base = now
        case .tomorrow:
            base = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        }
        let start = calendar.startOfDay(for: base)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }
}

/// Either the array Betfair promised or the fault it sent instead.
///
/// Decoded speculatively on every betting call because Betfair returns faults on
/// a 200 as readily as on a 400. Mapping only status codes lets an
/// `INVALID_SESSION_INFORMATION` through as an empty result, and an empty result
/// looks exactly like "no racing today".
enum BetfairRawResponse<Value: Decodable>: Decodable {
    case success([Value])
    case fault(BetfairFault)

    init(from decoder: Decoder) throws {
        // The happy path first: the overwhelmingly common case should not pay
        // for the error shape.
        if let values = try? [Value](from: decoder) {
            self = .success(values)
            return
        }
        let envelope = try BetfairFaultEnvelope(from: decoder)
        guard let code = envelope.errorCode else {
            throw APIError.decoding(nil)
        }
        self = .fault(BetfairFault(
            code: BetfairErrorCode(rawValue: code),
            details: envelope.detail?.apingException?.errorDetails))
    }
}

extension Array {
    /// Fixed-size chunks, for an API with a hard batch cap.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
