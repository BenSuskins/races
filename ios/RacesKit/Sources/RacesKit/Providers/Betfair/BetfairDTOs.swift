import Foundation

// Wire types for Betfair. Separate from the domain models on purpose: these
// mirror the exchange's JSON exactly, including its inconsistencies, so the
// mapping layer is the only place that has to know about them.

// MARK: - Identity

struct BetfairLoginResponse: Decodable {
    let token: String?
    let product: String?
    let status: String?
    let error: String?

    var isSuccess: Bool { status == "SUCCESS" && !(token ?? "").isEmpty }

    /// Betfair puts the reason in `error` and leaves `status` as `FAIL`. An empty
    /// `error` with a non-success status still has to produce a code, or the
    /// failure would report as a success with no token.
    var failureCode: String {
        let raw = (error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        let status = (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? "UNKNOWN" : status
    }
}

struct BetfairKeepAliveResponse: Decodable {
    let token: String?
    let status: String?
    let error: String?

    var isSuccess: Bool { status == "SUCCESS" }
}

// MARK: - Fault envelope

/// Betfair's error shape.
///
/// It arrives on a 200 as often as on a 400, which is why this is decoded
/// speculatively on every betting call rather than only on a failing status.
struct BetfairFaultEnvelope: Decodable {
    struct Detail: Decodable {
        struct Exception: Decodable {
            let errorCode: String?
            let errorDetails: String?
            let requestUUID: String?
        }
        let apingException: Exception?

        enum CodingKeys: String, CodingKey {
            case apingException = "APINGException"
        }
    }

    let faultcode: String?
    let faultstring: String?
    let detail: Detail?

    var errorCode: String? { detail?.apingException?.errorCode ?? faultstring }
}

// MARK: - listMarketCatalogue

struct BetfairMarketCatalogue: Decodable {
    struct Event: Decodable {
        let id: String?
        let name: String?
        let venue: String?
        let countryCode: String?
        let timezone: String?
    }

    struct RunnerCatalog: Decodable {
        let selectionId: Int64
        let runnerName: String?
        let status: String?
        /// `CLOTH_NUMBER`, `FORM`, `JOCKEY_NAME` and friends. Every value
        /// arrives as a string, including the numeric ones.
        let metadata: [String: String]?
    }

    let marketId: String
    let marketName: String?
    let marketStartTime: String?
    let event: Event?
    let runners: [RunnerCatalog]?
}

// MARK: - listMarketBook

struct BetfairMarketBook: Decodable {
    struct PriceSize: Decodable {
        let price: Double?
        let size: Double?
    }

    struct ExchangePrices: Decodable {
        let availableToBack: [PriceSize]?
        let availableToLay: [PriceSize]?
    }

    struct StartingPrices: Decodable {
        let nearPrice: Double?
        let farPrice: Double?
        /// Present only once the market has settled. The number the tracker
        /// needs for ROI.
        let actualSP: Double?
    }

    struct Runner: Decodable {
        let selectionId: Int64
        let status: String?
        let lastPriceTraded: Double?
        let ex: ExchangePrices?
        let sp: StartingPrices?

        var isActive: Bool { status == nil || status == "ACTIVE" }

        /// Best available to back is the *first* entry: Betfair orders the ladder
        /// best-price-first. Taking `max` would be wrong on the lay side and
        /// taking the last would be wrong on both.
        var bestBack: Double? { ex?.availableToBack?.first?.price }
        var bestLay: Double? { ex?.availableToLay?.first?.price }
    }

    let marketId: String
    let status: String?
    let isMarketDataDelayed: Bool?
    let runners: [Runner]?
}

// MARK: - Request bodies

struct BetfairMarketFilter: Encodable {
    var eventTypeIds: [String]?
    var marketCountries: [String]?
    var marketTypeCodes: [String]?
    var marketStartTime: BetfairTimeRange?
}

struct BetfairTimeRange: Encodable {
    let from: String
    let to: String
}

struct BetfairCatalogueRequest: Encodable {
    let filter: BetfairMarketFilter
    let marketProjection: [String]
    let maxResults: Int
    let sort: String
}

struct BetfairPriceProjection: Encodable {
    let priceData: [String]
    let virtualise: Bool
}

struct BetfairBookRequest: Encodable {
    let marketIds: [String]
    let priceProjection: BetfairPriceProjection
}
