import Foundation
import RacesKit

/// What the model is, laid out for reading.
///
/// Read-only. The weights are `RatingWeights.v1` and are not editable here on
/// purpose: `weightsID` is stamped into every stored tip, so changing a number
/// without changing the id silently invalidates the accuracy history — and
/// changing the id splits the record across two populations that the Record tab
/// would then have to keep apart. Tuning belongs behind the back-test, which can
/// say whether a changed weight is better or merely different.
///
/// It reads the store for one thing only: how much archive exists, which is what
/// decides whether the two strike-rate factors are actually contributing or
/// merely present.
@Observable
@MainActor
final class AlgorithmViewModel {

    /// One factor, with its weight and the reason behind it.
    ///
    /// `nonisolated` for the reason in CLAUDE.md: the app target infers isolated
    /// conformances, and this is compared in tests from nonisolated methods.
    nonisolated struct FactorRow: Identifiable, Equatable, Sendable {
        let id: FactorID
        let weight: Double
        /// Relative to the largest weight in the set, for the bar. Not the share
        /// of the total: a bar you can compare at a glance beats one that is
        /// arithmetically purer and visually flat.
        let relative: Double
        /// Carrying weight *and* able to produce a value right now. A strike-rate
        /// factor with a non-zero weight and no archive behind it is neither.
        let isActive: Bool
        let inactiveReason: String?

        var summary: String { id.summary }
        var rationale: String? { id.rationale }
    }

    private(set) var archivedRaceCount = 0
    /// Settled races the server can learn from, and how many it needs first.
    private(set) var trainingSamples: Int?
    private(set) var trainingMinimum: Int?
    /// Why the server's model could not be loaded, when it could not.
    private(set) var loadFailure: APIError?

    /// The weights the server is running. Starts as the kit's v2 so the
    /// screen has something true to show before the first response.
    private(set) var weights: RatingWeights
    private let link: ServerLink

    init(link: ServerLink, weights: RatingWeights = .v2) {
        self.link = link
        self.weights = weights
    }

    convenience init(environment: AppEnvironment) {
        self.init(link: environment.link)
    }

    func loadIfNeeded() async {
        do {
            let model = try await link.require().model()
            weights = model.active
            archivedRaceCount = model.archivedRaces
            trainingSamples = model.samples["settled"]
            trainingMinimum = model.samples["minimumRaces"]
            loadFailure = nil
        } catch {
            loadFailure = .from(error)
        }
    }

    // MARK: - Identity

    var modelVersion: String { RaceRater.modelVersion }
    var weightsID: String { weights.id }

    // MARK: - The blend

    var marketExponent: Double { weights.marketExponent }
    var formInfluence: Double { weights.formInfluence }
    var formInfluenceNoMarket: Double { weights.formInfluenceNoMarket }

    /// True when β is zero, i.e. the model is currently reproducing the market
    /// exactly. Not the shipped configuration, but it is the back-test's control
    /// and the screen should not quietly misreport it if it ever is.
    var isMarketOnly: Bool { formInfluence == 0 }

    // MARK: - Guardrails

    var clip: Double { weights.clip }
    var minimumMarketCoverage: Double { weights.minimumMarketCoverage }
    var minimumStrikeRateSample: Int { weights.minimumStrikeRateSample }

    var overroundMethodName: String {
        switch weights.overroundMethod {
        case .proportional: return "Proportional"
        case .power: return "Power"
        }
    }

    var overroundMethodDetail: String {
        switch weights.overroundMethod {
        case .proportional:
            return "Every implied probability is divided by the book sum. Simple and testable, but it under-corrects the favourite–longshot bias — a known weakness, recorded in docs/algorithm.md rather than hidden."
        case .power:
            return "Solves for the exponent that makes the probabilities sum to one, which spreads the overround unevenly as the market actually does."
        }
    }

    // MARK: - Form scoring

    var formDecay: Double { weights.formDecay }
    var formMaxRuns: Int { weights.formMaxRuns }
    var formSeasonBreakPenalty: Double { weights.formSeasonBreakPenalty }
    var formLongBreakPenalty: Double { weights.formLongBreakPenalty }

    /// Points per finishing position, in finishing order rather than dictionary
    /// order. Non-completions and tenth-or-worse are named rather than numbered.
    nonisolated struct FormPointRow: Identifiable, Equatable, Sendable {
        let label: String
        let points: Double
        var id: String { label }
    }

    var formPoints: [FormPointRow] {
        var rows: [FormPointRow] = []
        for position in 1...9 {
            guard let points = weights.formPoints[String(position)] else { continue }
            rows.append(FormPointRow(label: Self.ordinal(position), points: points))
        }
        if let points = weights.formPoints["tenOrWorse"] {
            rows.append(FormPointRow(label: "10th or worse", points: points))
        }
        if let points = weights.formPoints["nonCompletion"] {
            rows.append(FormPointRow(label: "Didn't complete", points: points))
        }
        return rows
    }

    private static func ordinal(_ value: Int) -> String {
        switch value {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(value)th"
        }
    }

    // MARK: - Factors

    /// Every factor the model knows about, heaviest first, with the zero-weight
    /// ones last.
    ///
    /// All twelve are listed, including the four at zero. A screen that showed
    /// only the live ones would imply the model considers nothing else, when the
    /// truth — code present, weight zero, reason given — is more useful and more
    /// honest.
    var factors: [FactorRow] {
        let weighted = FactorID.allCases.map { ($0, weights.weight(for: $0)) }
        let heaviest = weighted.map { $0.1 }.max() ?? 1

        return weighted
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.label < rhs.0.label
            }
            .map { id, weight in
                let inactive = inactiveReason(for: id, weight: weight)
                return FactorRow(
                    id: id,
                    weight: weight,
                    relative: heaviest > 0 ? weight / heaviest : 0,
                    isActive: inactive == nil,
                    inactiveReason: inactive)
            }
    }

    var liveFactorCount: Int { factors.filter(\.isActive).count }
    var totalFactorCount: Int { FactorID.allCases.count }

    /// Why a factor is not contributing: either it carries no weight, or it does
    /// but has nothing to read yet.
    ///
    /// The second case is the one worth surfacing. A user who sees a non-zero
    /// weight beside "Jockey strike rate" would reasonably assume it is in play,
    /// and on a fresh install it is not — the archive is empty, so the factor
    /// reports `missingData` for every runner and contributes nothing.
    private func inactiveReason(for id: FactorID, weight: Double) -> String? {
        if weight == 0 { return "Weight is zero, so it contributes nothing." }
        switch id {
        case .jockeyStrikeRate, .trainerStrikeRate:
            guard archivedRaceCount == 0 else { return nil }
            return "Waiting on the archive. Nothing is recorded yet, so this reports no value rather than a misleading zero."
        default:
            return nil
        }
    }
}
