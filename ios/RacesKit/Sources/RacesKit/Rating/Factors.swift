import Foundation

// The free-tier factor set. Each one reads a runner and returns a raw value where
// higher is always better; standardisation and weighting happen elsewhere.
//
// Several ship at zero weight with their reasoning attached. That is deliberate:
// a factor that cannot be substantiated should say so rather than guess, and the
// back-test can promote it once it has earned a weight.

/// The handicapper's mark. The strongest single factor available for free, and
/// particularly informative in handicaps, where it is a considered opinion of
/// every runner on one common scale.
public struct OfficialRatingFactor: RatingFactor {
    public let id = FactorID.officialRating
    public init() {}

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        guard let rating = runner.officialRating else {
            return .missing("no official rating", display: "Unrated")
        }
        return .value(Double(rating), "OR \(rating)")
    }
}

/// Where a runner sits inside the band the race is framed for.
///
/// A mark of 95 is top weight in a 0-95 handicap and mid-division in a 0-110. The
/// raw rating cannot express that; this can.
public struct HandicapBandPositionFactor: RatingFactor {
    public let id = FactorID.handicapBandPosition
    public init() {}

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        guard context.race.isHandicap else {
            return .notApplicable("not a handicap")
        }
        guard let band = context.race.ratingBand, band.upperBound > band.lowerBound else {
            return .notApplicable("no rating band published")
        }
        guard let rating = runner.officialRating else {
            return .missing("no official rating", display: "Unrated")
        }

        let span = Double(band.upperBound - band.lowerBound)
        let position = (Double(rating) - Double(band.lowerBound)) / span
        let percent = Int((position * 100).rounded())
        return .value(position, "\(percent)% up the \(band.lowerBound)-\(band.upperBound) band")
    }
}

/// Recency-weighted recent form.
///
/// Remember what this cannot see: the form string says a horse finished first, not
/// *in what*. A Class 7 seller and a Group 1 both read `1`.
public struct RecentFormFactor: RatingFactor {
    public let id = FactorID.recentForm
    private let scorer: FormScorer

    public init(scorer: FormScorer = FormScorer()) {
        self.scorer = scorer
    }

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        let line = FormParser.parse(runner.form)
        guard let score = scorer.score(line) else {
            return .missing("no recorded form", display: "Unraced")
        }
        return .value(score, line.raw)
    }
}

public struct WonLastTimeFactor: RatingFactor {
    public let id = FactorID.wonLastTime
    public init() {}

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        let line = FormParser.parse(runner.form)
        guard let won = line.wonLastTime else {
            return .missing("no recorded form", display: "Unraced")
        }
        return .value(won ? 1 : 0, won ? "Won last time" : "Did not win last time")
    }
}

/// Share of recent runs completed. Real information over obstacles, and close to
/// none on the Flat where almost everything finishes.
public struct CompletionRateFactor: RatingFactor {
    public let id = FactorID.completionRate
    public init() {}

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        guard context.race.type.isJumps else {
            return .notApplicable("only meaningful over obstacles")
        }
        let line = FormParser.parse(runner.form)
        guard let rate = line.completionRate else {
            return .missing("no recorded form", display: "Unraced")
        }
        let percent = Int((rate * 100).rounded())
        return .value(rate, "Completed \(percent)% of recent runs")
    }
}

/// Days since the last run, as a piecewise response.
///
/// Deliberately **not linear**: both a very quick reappearance and a long layoff
/// are mild negatives, with a broad optimum in between. The whole effect is small
/// and heavily confounded by trainer intent, which we cannot observe — hence a
/// small weight and a flag in `docs/algorithm.md`.
public struct DaysSinceLastRunFactor: RatingFactor {
    public let id = FactorID.daysSinceLastRun
    public init() {}

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        guard let days = runner.daysSinceLastRun else {
            return .missing("no recorded previous run", display: "First run")
        }
        return .value(Self.freshness(days: days), "\(days) days")
    }

    /// 0...1, peaking over the two-to-five-week window most trainers aim for.
    static func freshness(days: Int) -> Double {
        switch days {
        case ..<0: return 0.5
        case 0..<7: return 0.55
        case 7..<14: return 0.80
        case 14..<36: return 1.00
        case 36..<61: return 0.85
        case 61..<121: return 0.60
        case 121..<241: return 0.35
        default: return 0.20
        }
    }
}

/// Age, and only where the race actually mixes ages.
///
/// In a race confined to one age group every runner scores identically, so the
/// factor stands aside rather than contributing noise.
public struct AgeFactor: RatingFactor {
    public let id = FactorID.age
    public init() {}

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        guard let band = context.race.ageBand, band.contains("+") else {
            return .notApplicable("race is confined to one age group")
        }
        guard let age = runner.age else {
            return .missing("age unknown")
        }

        // Peak racing age differs by code: Flat horses mature earlier than jumpers.
        let peak: Double = context.race.type.isJumps ? 8 : 4.5
        return .value(-abs(Double(age) - peak), "\(age)yo")
    }
}

/// Weight carried, negated so that less is better.
///
/// ⚠️ **Statistically dubious, and shipped near zero on purpose.** In a handicap,
/// weight *is* the handicapper's equaliser: higher weight means a better horse and
/// the whole intent is that it cancels out. Reading it as "less weight is better"
/// is close to backwards; reading it the other way double-counts the official
/// rating. Left in place for the back-test to settle.
public struct WeightCarriedFactor: RatingFactor {
    public let id = FactorID.weightCarried
    public init() {}

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        guard let pounds = runner.weightPounds, pounds > 0 else {
            return .missing("no weight published")
        }
        return .value(-Double(pounds), runner.weightDisplay ?? "\(pounds) lb")
    }
}

/// Draw bias — **present but deliberately inert**.
///
/// Draw bias is real and can be decisive over sprint trips. But it is a
/// course × distance × going × field-size interaction, and the free tier gives us
/// no bias data at all. Inventing a table from memory would produce confident
/// nonsense, which is the worst possible failure for an app that tells you what to
/// back. So the factor reports honestly that it has nothing to say.
///
/// Once `ResultStore` holds enough British Flat racing, an empirical table derived
/// from the app's own archive can fill this in — and only then does the weight
/// come off zero.
public struct DrawFactor: RatingFactor {
    public let id = FactorID.draw
    public init() {}

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        guard context.race.type == .flat else {
            return .notApplicable("the draw doesn't apply over obstacles")
        }
        guard let draw = runner.draw else {
            return .missing("no draw published")
        }
        return .notApplicable("no draw-bias data for this course yet", display: "Stall \(draw)")
    }
}

/// Headgear — **present but inert**, for a different reason.
///
/// The predictive angle is *first-time* headgear, and spotting that needs a
/// headgear history. `headgear_run` is a paid field, so on the free tier we can
/// see that a horse wears blinkers but not whether today is the first time — which
/// is the only part that carries information.
public struct HeadgearFactor: RatingFactor {
    public let id = FactorID.headgear
    public init() {}

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        let display = runner.headgear.map { "Wearing \($0)" } ?? "No headgear"
        return .requiresPaidTier(
            "first-time headgear needs a headgear history",
            display: display
        )
    }
}

/// Strike rates from the app's own accumulated results.
///
/// These are the quiet payoff of keeping an on-device archive: they cost nothing
/// extra and improve every day the app runs. They are also the factors most likely
/// to mislead early, so they stay silent until the sample is worth consulting and
/// are shrunk toward the field mean even then.
public struct StrikeRateFactor: RatingFactor {
    public enum Subject: Sendable {
        case jockey
        case trainer
    }

    public let id: FactorID
    private let subject: Subject
    private let minimumSample: Int

    public init(subject: Subject, minimumSample: Int = 30) {
        self.subject = subject
        self.minimumSample = minimumSample
        self.id = subject == .jockey ? .jockeyStrikeRate : .trainerStrikeRate
    }

    public func value(for runner: Runner, in context: FactorContext) -> FactorValue {
        guard let provider = context.strikeRates else {
            return .missing("no results archive yet")
        }
        let subjectID = subject == .jockey ? runner.jockeyID : runner.trainerID
        guard let subjectID else {
            return .missing("not identified")
        }
        guard let record = subject == .jockey
            ? provider.jockeyStrikeRate(id: subjectID)
            : provider.trainerStrikeRate(id: subjectID)
        else {
            return .missing("no record in the archive yet")
        }
        guard record.runs >= minimumSample else {
            return .missing("only \(record.runs) runs recorded so far")
        }

        let smoothed = record.smoothed(towards: provider.baselineStrikeRate)
        let percent = Int((smoothed * 100).rounded())
        return .value(smoothed, "\(percent)% from \(record.runs) runs")
    }
}
