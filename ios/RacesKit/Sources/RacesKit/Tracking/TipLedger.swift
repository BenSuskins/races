import Foundation

/// The record of every tip made, and the rules about when one may be written.
///
/// ## The sealing rule, which is what makes the tracker mean anything
///
/// A tip is a **draft** until the race is close to off, and **immutable**
/// afterwards:
///
/// - More than five minutes before the off, re-opening a race recomputes and
///   overwrites. Prices move and non-runners are declared; the latest view is
///   the useful one.
/// - Inside the last five minutes, the first write **seals** the record. Later
///   recomputes may be displayed but are never stored.
/// - Once the race has run, no record is created at all. A race first opened
///   after it was run never enters the tracker.
///
/// Without this, the tracker would measure what the model thought once the
/// results were already in, which is worth precisely nothing — and would look
/// impressive while being worth nothing, which is worse.
public struct TipLedger: Codable, Hashable, Sendable {

    /// How close to the off a tip stops being a draft.
    public static let sealWindow: TimeInterval = 5 * 60

    public enum RecordOutcome: Hashable, Sendable {
        /// First time we have seen this race.
        case created
        /// Overwrote an earlier draft.
        case updated
        /// Stored and sealed: this is the version that will be judged.
        case sealed
        /// Already sealed; the new assessment was discarded.
        case rejectedAlreadySealed
        /// The race has run. Nothing is recorded.
        case rejectedRaceStarted
        /// The assessment had no runners to choose from.
        case rejectedNoSelection

        public var didStore: Bool {
            switch self {
            case .created, .updated, .sealed: return true
            case .rejectedAlreadySealed, .rejectedRaceStarted, .rejectedNoSelection: return false
            }
        }
    }

    private var storage: [String: TipRecord]

    public init(tips: [TipRecord] = []) {
        self.storage = Dictionary(tips.map { ($0.raceID, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public var tips: [TipRecord] {
        storage.values.sorted { lhs, rhs in
            let left = lhs.offAt ?? lhs.createdAt
            let right = rhs.offAt ?? rhs.createdAt
            return left == right ? lhs.raceID < rhs.raceID : left > right
        }
    }

    public var count: Int { storage.count }

    public func tip(forRace raceID: String) -> TipRecord? {
        storage[raceID]
    }

    /// Tips whose race has run but which have no final outcome yet.
    public func awaitingReconciliation(now: Date = Date()) -> [TipRecord] {
        tips.filter { tip in
            guard let offAt = tip.offAt, offAt <= now else { return false }
            switch tip.outcome {
            case .none, .some(.unresolved):
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Recording

    @discardableResult
    public mutating func record(
        _ assessment: RaceAssessment,
        race: Race,
        now: Date = Date()
    ) -> RecordOutcome {
        guard let candidate = TipRecord(assessment: assessment, race: race, now: now) else {
            return .rejectedNoSelection
        }
        return store(candidate, offAt: race.offDateTime, now: now)
    }

    @discardableResult
    mutating func store(_ candidate: TipRecord, offAt: Date?, now: Date) -> RecordOutcome {
        let existing = storage[candidate.raceID]

        if existing?.isSealed == true {
            return .rejectedAlreadySealed
        }

        // A race with no known off time cannot be judged against the window, so
        // it is sealed on first write. Conservative on purpose: better to record
        // a slightly stale tip than to leave the door open to recording one after
        // the result is known.
        guard let offAt else {
            var sealed = candidate
            sealed.sealedAt = now
            storage[candidate.raceID] = sealed
            return .sealed
        }

        guard now < offAt else {
            return .rejectedRaceStarted
        }

        if now >= offAt.addingTimeInterval(-Self.sealWindow) {
            var sealed = candidate
            sealed.sealedAt = now
            storage[candidate.raceID] = sealed
            return .sealed
        }

        storage[candidate.raceID] = candidate
        return existing == nil ? .created : .updated
    }

    // MARK: - Settling

    /// Apply a settlement. Outcomes may be revised while a tip is unresolved, but
    /// never once it has a final one — a settled race does not un-settle.
    @discardableResult
    public mutating func settle(
        raceID: String,
        outcome: TipOutcome,
        favourite: FavouriteOutcome? = nil
    ) -> Bool {
        guard var tip = storage[raceID] else { return false }

        if let current = tip.outcome, current.isSettled || current.isVoid {
            return false
        }

        tip.outcome = outcome
        if let favourite {
            tip.favouriteOutcome = favourite
        }
        storage[raceID] = tip
        return true
    }

    public mutating func replace(_ tip: TipRecord) {
        storage[tip.raceID] = tip
    }
}
