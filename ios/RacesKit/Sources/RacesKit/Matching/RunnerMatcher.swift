import Foundation

/// One runner joined to one selection.
public struct RunnerPairing: Hashable, Sendable {
    /// How the pairing was established. Recorded because it is the single most
    /// useful thing to know when a price turns out to be on the wrong horse.
    public enum Basis: String, Codable, Sendable {
        case clothNumber
        case exactName
        case similarName

        public var displayName: String {
            switch self {
            case .clothNumber: return "Saddle cloth"
            case .exactName: return "Name"
            case .similarName: return "Similar name"
            }
        }
    }

    public let horseID: String
    public let horseName: String
    public let selectionID: Int64
    public let basis: Basis

    public init(horseID: String, horseName: String, selectionID: Int64, basis: Basis) {
        self.horseID = horseID
        self.horseName = horseName
        self.selectionID = selectionID
        self.basis = basis
    }
}

/// The result of joining one field to one market's selections.
public struct RunnerMatchResult: Hashable, Sendable {
    public let pairings: [RunnerPairing]
    /// Our runners with no selection. Ordinary: a horse withdrawn on one feed
    /// before the other.
    public let unmatchedHorseIDs: [String]
    /// Selections with no runner of ours.
    public let unmatchedSelectionIDs: [Int64]

    /// Share of our runners that found a selection. What the overlap threshold
    /// is applied to.
    public var overlap: Double {
        let total = pairings.count + unmatchedHorseIDs.count
        guard total > 0 else { return 0 }
        return Double(pairings.count) / Double(total)
    }

    public var pairingsByHorseID: [String: RunnerPairing] {
        Dictionary(pairings.map { ($0.horseID, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Joins our runners to an exchange's selections.
///
/// Three passes, in this order, each only considering what the previous ones left
/// over. Order matters, and the first pass is first because `CLAUDE.md` says so:
/// **cloth number is the primary key, names are the fallback.** Betfair runner
/// names carry country suffixes and cloth prefixes, so name matching is the more
/// brittle of the two.
///
/// Two ways a cloth number can mislead, and what is done about each:
///
/// - **The feeds disagree about numbering**, usually after a withdrawal, and then
///   matching on the number pairs two different horses with total confidence. So
///   the cloth pass refuses a pairing whose exchange name exactly matches a
///   *different* one of our runners. Cheap to detect, and the one case where
///   cloth-first would otherwise produce a confident mismatch.
/// - **The two fields are not the same race at all.** Every race numbers its
///   runners from one, so cloth numbers agree between *any* two races of the same
///   size. That makes them worthless as evidence that a market belongs to a race
///   — which is why `RaceMatcher` scores candidate markets with
///   `allowClothNumbers: false` and only enables them once it has decided which
///   market it is looking at. Getting this the wrong way round produces a
///   matcher that confidently prices every race off whatever market happens to
///   share its course and time.
public enum RunnerMatcher {

    /// - Parameter allowClothNumbers: whether the cloth pass runs. Pass `false`
    ///   while deciding *which* market a race belongs to: cloth numbers cannot
    ///   distinguish one race from another, so used there they manufacture
    ///   agreement. Names are the only evidence that identifies a field.
    public static func match(
        runners: [Runner],
        selections: [ExchangeRunner],
        tolerances: MatchingTolerances = .default,
        allowClothNumbers: Bool = true
    ) -> RunnerMatchResult {
        var remainingRunners = runners
        var remainingSelections = selections
        var pairings: [RunnerPairing] = []

        // Built once, over the whole field, so the contradiction check in the
        // cloth pass can see names it has not reached yet.
        let ourKeys: [String: [Runner]] = Dictionary(
            grouping: runners, by: { HorseNameNormaliser.key($0.name) })

        // MARK: Pass 1 — saddle cloth
        //
        // Exact, and unaffected by how either side spells a name. Skipped
        // entirely while candidate markets are still being scored.
        var clothPairings: [RunnerPairing] = []
        for runner in (allowClothNumbers ? remainingRunners : [Runner]()) {
            guard let cloth = runner.clothNumber, cloth > 0 else { continue }
            let candidates = remainingSelections.filter { $0.clothNumber == cloth }
            guard candidates.count == 1, let selection = candidates.first else { continue }

            // The contradiction guard. If this selection's name is unambiguously
            // one of our *other* runners, the numbering disagrees and the cloth
            // pairing is the thing to distrust, not the name.
            let selectionKey = HorseNameNormaliser.key(selection.name)
            if let namesakes = ourKeys[selectionKey], namesakes.count == 1,
               let namesake = namesakes.first, namesake.id != runner.id {
                continue
            }

            clothPairings.append(
                RunnerPairing(
                    horseID: runner.id, horseName: runner.name,
                    selectionID: selection.id, basis: .clothNumber))
        }
        consume(clothPairings, from: &remainingRunners, &remainingSelections, into: &pairings)

        // MARK: Pass 2 — exact normalised name
        var namePairings: [RunnerPairing] = []
        let selectionKeys: [String: [ExchangeRunner]] = Dictionary(
            grouping: remainingSelections, by: { HorseNameNormaliser.key($0.name) })

        for runner in remainingRunners {
            let key = HorseNameNormaliser.key(runner.name)
            guard !key.isEmpty, let candidates = selectionKeys[key],
                  candidates.count == 1, let selection = candidates.first else { continue }

            namePairings.append(
                RunnerPairing(
                    horseID: runner.id, horseName: runner.name,
                    selectionID: selection.id, basis: .exactName))
        }
        consume(namePairings, from: &remainingRunners, &remainingSelections, into: &pairings)

        // MARK: Pass 3 — near-identical name
        //
        // Only where exactly one candidate is within the limit. A tie is a
        // refusal: no price at all beats a price on the wrong horse.
        if tolerances.maximumNameDistance > 0 {
            var fuzzyPairings: [RunnerPairing] = []
            for runner in remainingRunners {
                let key = HorseNameNormaliser.key(runner.name)
                guard !key.isEmpty else { continue }

                var best: (selection: ExchangeRunner, distance: Int)?
                var tied = false

                for selection in remainingSelections {
                    let candidateKey = HorseNameNormaliser.key(selection.name)
                    guard let distance = HorseNameNormaliser.distance(
                        key, candidateKey, limit: tolerances.maximumNameDistance) else { continue }

                    if let current = best {
                        if distance < current.distance {
                            best = (selection, distance)
                            tied = false
                        } else if distance == current.distance {
                            tied = true
                        }
                    } else {
                        best = (selection, distance)
                    }
                }

                guard !tied, let match = best else { continue }
                fuzzyPairings.append(
                    RunnerPairing(
                        horseID: runner.id, horseName: runner.name,
                        selectionID: match.selection.id, basis: .similarName))
            }
            consume(fuzzyPairings, from: &remainingRunners, &remainingSelections, into: &pairings)
        }

        return RunnerMatchResult(
            pairings: pairings,
            unmatchedHorseIDs: remainingRunners.map(\.id),
            unmatchedSelectionIDs: remainingSelections.map(\.id))
    }

    /// Accepts only pairings that are one-to-one within the pass.
    ///
    /// A pass can propose two runners for one selection — two of our horses whose
    /// names are both a near miss for the same name, say. Neither is safe, so
    /// both are dropped and left for a later pass or for the unmatched list.
    private static func consume(
        _ proposed: [RunnerPairing],
        from runners: inout [Runner],
        _ selections: inout [ExchangeRunner],
        into accepted: inout [RunnerPairing]
    ) {
        var countBySelection: [Int64: Int] = [:]
        for pairing in proposed {
            countBySelection[pairing.selectionID, default: 0] += 1
        }

        let unique = proposed.filter { countBySelection[$0.selectionID] == 1 }
        guard !unique.isEmpty else { return }

        let takenHorseIDs = Set(unique.map(\.horseID))
        let takenSelectionIDs = Set(unique.map(\.selectionID))

        accepted.append(contentsOf: unique)
        runners.removeAll { takenHorseIDs.contains($0.id) }
        selections.removeAll { takenSelectionIDs.contains($0.id) }
    }
}
