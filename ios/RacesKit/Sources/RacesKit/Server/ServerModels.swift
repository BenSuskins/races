import Foundation

// What the Races server sends. The domain objects inside — `Race`,
// `RaceAssessment`, `TipRecord`, `AccuracyReport`, `RatingWeights` — are the
// kit's own types: the server's JSON is written to their synthesised Codable
// shape, so the app decodes the server with the models it already had.
//
// Codable rather than Decodable so the app can keep the last response on disk
// and still show a card when the server is out of reach.

/// Where the server is and how to prove who we are.
public struct ServerConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let token: String

    /// The Traefik route on the homelab, reachable over the LAN and Tailscale.
    public static let defaultBaseURL = URL(string: "https://races-api.suskins.co.uk")!

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// The configuration in the store, or nil when there is no token.
    ///
    /// A blank address means the default one; a blank token means not
    /// configured. An address that is not an http(s) URL is treated as blank
    /// rather than as a configuration that can only fail.
    public init?(reading store: any CredentialsStoring) throws {
        func value(_ slot: CredentialSlot) throws -> String? {
            guard let raw = try store.read(slot) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let token = try value(.serverToken) else { return nil }
        var baseURL = Self.defaultBaseURL
        if let raw = try value(.serverURL), let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
           url.host != nil {
            baseURL = url
        }
        self.init(baseURL: baseURL, token: token)
    }
}

/// Why a race has no market, as the server's matcher reported it.
public struct ServerRefusal: Codable, Hashable, Sendable {
    public let kind: String
    public let displayName: String
    public let marketID: String?
    public let marketIDs: [String]?
    public let overlap: Double?
}

/// One day's card with everything the Racing and Tips tabs show.
public struct ServerRacecard: Codable, Hashable, Sendable {
    public let day: RaceDay
    public let date: String
    public let fetchedAt: Date?
    public let races: [Race]
    public let assessments: [String: RaceAssessment]
    public let tips: [String: TipRecord]
    public let results: [String: RaceResult]
    public let refusals: [String: ServerRefusal]
    public let archivedRaces: Int

    public init(
        day: RaceDay,
        date: String,
        fetchedAt: Date? = nil,
        races: [Race],
        assessments: [String: RaceAssessment] = [:],
        tips: [String: TipRecord] = [:],
        results: [String: RaceResult] = [:],
        refusals: [String: ServerRefusal] = [:],
        archivedRaces: Int = 0
    ) {
        self.day = day
        self.date = date
        self.fetchedAt = fetchedAt
        self.races = races
        self.assessments = assessments
        self.tips = tips
        self.results = results
        self.refusals = refusals
        self.archivedRaces = archivedRaces
    }
}

/// One race in full.
public struct ServerRaceDetail: Codable, Hashable, Sendable {
    public let race: Race
    public let assessment: RaceAssessment?
    public let tip: TipRecord?
    public let result: RaceResult?
    public let snapshot: MarketSnapshot?
    public let refusal: ServerRefusal?

    public init(
        race: Race,
        assessment: RaceAssessment? = nil,
        tip: TipRecord? = nil,
        result: RaceResult? = nil,
        snapshot: MarketSnapshot? = nil,
        refusal: ServerRefusal? = nil
    ) {
        self.race = race
        self.assessment = assessment
        self.tip = tip
        self.result = result
        self.snapshot = snapshot
        self.refusal = refusal
    }
}

/// The accuracy record, computed on the server over every tip it holds —
/// its own and any history a phone uploaded.
public struct ServerRecord: Codable, Hashable, Sendable {
    public let weightsID: String?
    public let activeWeightsID: String?
    public let commission: Double
    public let report: AccuracyReport
    /// The 30 newest tips in this weight-set population, with their frozen rating details.
    public let recentTips: [TipRecord]?
    public let weightsInUse: [String: Int]
    /// Tips by where they came from: `server`, or `device:<name>`.
    public let sources: [String: Int]
    public let archivedRaces: Int

    public init(
        weightsID: String? = nil,
        activeWeightsID: String? = nil,
        commission: Double = AccuracyCalculator.defaultCommission,
        report: AccuracyReport,
        recentTips: [TipRecord]? = nil,
        weightsInUse: [String: Int] = [:],
        sources: [String: Int] = [:],
        archivedRaces: Int = 0
    ) {
        self.weightsID = weightsID
        self.activeWeightsID = activeWeightsID
        self.commission = commission
        self.report = report
        self.recentTips = recentTips
        self.weightsInUse = weightsInUse
        self.sources = sources
        self.archivedRaces = archivedRaces
    }
}

/// A weight set the server knows, and where it came from.
public struct ServerWeights: Codable, Hashable, Sendable {
    public let weights: RatingWeights
    /// `preset`, `trained` or `device`.
    public let origin: String
    public let createdAt: Date
    public let active: Bool
}

/// The model as the server runs it. Read-only, as the Model tab has always
/// been.
public struct ServerModel: Codable, Hashable, Sendable {
    public let modelVersion: String
    public let active: RatingWeights
    public let weights: [ServerWeights]
    /// `settled`, `pending` and `minimumRaces` for retraining.
    public let samples: [String: Int]
    public let archivedRaces: Int

    public init(
        modelVersion: String = RaceRater.modelVersion,
        active: RatingWeights,
        weights: [ServerWeights] = [],
        samples: [String: Int] = [:],
        archivedRaces: Int = 0
    ) {
        self.modelVersion = modelVersion
        self.active = active
        self.weights = weights
        self.samples = samples
        self.archivedRaces = archivedRaces
    }
}

/// Betfair's classified login failure, carrying its own code verbatim.
public struct ServerLoginFailure: Codable, Hashable, Sendable {
    public let code: String
    public let failureClass: String
    public let message: String

    enum CodingKeys: String, CodingKey {
        case code
        case failureClass = "class"
        case message
    }

    public var requiresCertificateLogin: Bool { failureClass == "certificateRequired" }
    public var requiresUserAction: Bool { failureClass == "userActionRequired" }
    public var isInformational: Bool { requiresCertificateLogin || requiresUserAction }
}

/// One provider's health, as the server sees it.
public struct ServerProviderStatus: Codable, Hashable, Sendable {
    public let configured: Bool
    public let healthy: Bool
    public let detail: String?
    public let loginFailure: ServerLoginFailure?

    public init(configured: Bool, healthy: Bool, detail: String? = nil, loginFailure: ServerLoginFailure? = nil) {
        self.configured = configured
        self.healthy = healthy
        self.detail = detail
        self.loginFailure = loginFailure
    }
}

/// When a scheduled job last ran, and how it went.
public struct ServerJobRun: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let startedAt: Date?
    public let finishedAt: Date?
    public let succeededAt: Date?
    public let error: String?
    public let summary: String?

    public var id: String { name }
}

/// A stored back-test, or a named sweep, as returned by `GET /v1/backtests`.
public struct ServerBacktest: Decodable, Hashable, Sendable, Identifiable {
    public let id: Int64
    public let createdAt: Date
    public let weightsID: String
    public let report: ServerBacktestReport
}

public struct ServerBacktestReport: Decodable, Hashable, Sendable {
    public let from: String?
    public let to: String?
    public let corpusID: String?
    public let sharedCorpusID: String?
    public let highestProbability: ServerBacktestArm?
    public let favourite: ServerBacktestArm?
    public let marketLogLoss: Double?
    public let reports: [ServerBacktestVariant]?
}

public struct ServerBacktestVariant: Decodable, Hashable, Sendable, Identifiable {
    public let name: String
    public let report: ServerBacktestReport

    public var id: String { name }
}

public struct ServerBacktestArm: Decodable, Hashable, Sendable {
    public let races: Int
    public let wins: Int
    public let strikeRate: Double?
    public let logLoss: Double?
    public let brier: Double?
}

/// `GET /v1/status`: what Settings shows under "Test connection".
public struct ServerStatus: Codable, Hashable, Sendable {
    public let version: String
    public let serverTime: Date
    public let activeWeightsID: String
    public let racingAPI: ServerProviderStatus
    public let betfair: ServerProviderStatus
    public let jobs: [ServerJobRun]
    public let counts: [String: Int]

    public init(
        version: String = "test",
        serverTime: Date = Date(timeIntervalSince1970: 0),
        activeWeightsID: String = "v3",
        racingAPI: ServerProviderStatus,
        betfair: ServerProviderStatus,
        jobs: [ServerJobRun] = [],
        counts: [String: Int] = [:]
    ) {
        self.version = version
        self.serverTime = serverTime
        self.activeWeightsID = activeWeightsID
        self.racingAPI = racingAPI
        self.betfair = betfair
        self.jobs = jobs
        self.counts = counts
    }
}

/// The history a device collected before the server existed: the stored
/// documents, byte for byte.
public struct ServerHistoryUpload: Sendable {
    public let device: String
    public let tips: Data?
    public let archive: Data?
    public let training: Data?

    public init(device: String, tips: Data?, archive: Data?, training: Data?) {
        self.device = device
        self.tips = tips
        self.archive = archive
        self.training = training
    }

    public var isEmpty: Bool { tips == nil && archive == nil && training == nil }

    /// `{"device": …, "tips": <tips.json>, …}` — the documents embedded as
    /// they are rather than decoded and re-encoded, so nothing the server
    /// reads was changed on the way.
    public func body() throws -> Data {
        var body = Data("{\"device\":".utf8)
        body += try JSONEncoder().encode(device)
        for (key, document) in [("tips", tips), ("archive", archive), ("training", training)] {
            body += Data(",\"\(key)\":".utf8)
            if let document, (try? JSONSerialization.jsonObject(with: document)) != nil {
                body += document
            } else {
                body += Data("null".utf8)
            }
        }
        body += Data("}".utf8)
        return body
    }
}

/// What an upload changed. A second upload of the same history reports zeros.
public struct ServerImportSummary: Codable, Hashable, Sendable {
    public let device: String
    public let tipsReceived: Int
    public let tipsAdded: Int
    public let tipsReplaced: Int
    public let tipsKept: Int
    public let archiveRacesAdded: Int
    public let archiveSkipped: Bool
    public let samplesReceived: Int
    public let samplesAdded: Int
    public let pendingAdded: Int
    public let weightsAdded: [String]
    public let unreadableDocuments: [String]
}
