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

    /// Betfair documents metadata as string values, but the live feed can
    /// contain numeric/null values. The app consumes metadata as strings, so
    /// coerce scalar values instead of letting one odd field invalidate a
    /// whole catalogue.
    private enum MetadataValue: Decodable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Int64.self) {
                self = .int(value)
            } else if let value = try? container.decode(Double.self) {
                self = .double(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                throw DecodingError.typeMismatch(
                    MetadataValue.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected a scalar Betfair metadata value"))
            }
        }

        var stringValue: String? {
            switch self {
            case .string(let value): return value
            case .int(let value): return String(value)
            case .double(let value): return String(value)
            case .bool(let value): return String(value)
            case .null: return nil
            }
        }
    }

    struct RunnerCatalog: Decodable {
        let selectionId: Int64
        let runnerName: String?
        let status: String?
        /// `CLOTH_NUMBER`, `FORM`, `JOCKEY_NAME` and friends. Values are
        /// normally strings, but the decoder tolerates numeric/null values.
        let metadata: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case selectionId
            case runnerName
            case status
            case metadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            selectionId = try container.decode(Int64.self, forKey: .selectionId)
            runnerName = try container.decodeIfPresent(String.self, forKey: .runnerName)
            status = try container.decodeIfPresent(String.self, forKey: .status)

            guard let raw = try container.decodeIfPresent(
                [String: MetadataValue].self, forKey: .metadata) else {
                metadata = nil
                return
            }
            metadata = raw.compactMapValues(\.stringValue)
        }
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
