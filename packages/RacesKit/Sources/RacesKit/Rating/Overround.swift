import Foundation

/// Turns exchange prices into probabilities that sum to one.
///
/// A betting book always sums to more than 100% — the overround. On the Betfair
/// exchange it is small, typically 1–5%, but it still has to come out before the
/// prices can be treated as probabilities and anchored against.
public enum Overround {

    public enum Method: String, Codable, Hashable, Sendable {
        /// Divide every probability by the book sum. Trivially correct, trivially
        /// testable, and the default.
        case proportional
        /// Solve for `k` such that `Σ pᵢ^k = 1`. Corrects for the fact that the
        /// overround is not spread evenly.
        case power
    }

    /// Raw implied probability for one runner, before de-vigging.
    ///
    /// Source priority, best first:
    /// 1. **Mid of back and lay**, when both exist and the spread is sane. The
    ///    true price sits between them; taking the back price alone understates
    ///    every runner.
    /// 2. **Back price** on its own.
    /// 3. **Last traded**, for a market that has gone quiet.
    /// 4. **Forecast price** — which matters more than it looks. Tomorrow's markets
    ///    have little or no liquidity, so this is often the only anchor a card has
    ///    before it starts trading.
    ///
    /// Withdrawn runners return nil and are excluded from the book entirely rather
    /// than de-vigged alongside the rest.
    public static func impliedProbability(
        _ price: RunnerPrice,
        maximumSpreadRatio: Double = 1.35
    ) -> Double? {
        guard price.isActive else { return nil }

        if let back = price.backPrice, back > 1,
           let lay = price.layPrice, lay > 1,
           lay / back <= maximumSpreadRatio {
            return (1 / back + 1 / lay) / 2
        }
        if let back = price.backPrice, back > 1 { return 1 / back }
        if let lastTraded = price.lastTraded, lastTraded > 1 { return 1 / lastTraded }
        if let forecast = price.forecastPrice, forecast > 1 { return 1 / forecast }
        return nil
    }

    /// Normalise raw implied probabilities so the present ones sum to 1.
    /// Runners without a price stay nil rather than being given a share.
    public static func normalise(
        _ raw: [Double?],
        method: Method = .proportional
    ) -> [Double?] {
        let present = raw.compactMap { $0 }.filter { $0 > 0 && $0.isFinite }
        guard !present.isEmpty else {
            return Array(repeating: nil, count: raw.count)
        }

        let exponent: Double
        switch method {
        case .proportional:
            exponent = 1
        case .power:
            exponent = powerExponent(present)
        }

        let adjusted = raw.map { value -> Double? in
            guard let value, value > 0, value.isFinite else { return nil }
            return exponent == 1 ? value : pow(value, exponent)
        }
        let total = adjusted.compactMap { $0 }.reduce(0, +)
        guard total > 0, total.isFinite else {
            return Array(repeating: nil, count: raw.count)
        }
        return adjusted.map { $0.map { $0 / total } }
    }

    /// Bisection for the exponent `k` where `Σ pᵢ^k = 1`.
    ///
    /// For probabilities in (0,1), `p^k` shrinks as `k` grows, so the sum is
    /// monotonically decreasing in `k` and bisection is well behaved. When the
    /// root is not bracketed — a book that already sums below 1, say — this
    /// returns 1, which makes the power method fall back to proportional rather
    /// than inventing an exponent.
    static func powerExponent(
        _ probabilities: [Double],
        lowerBound: Double = 0.5,
        upperBound: Double = 3.0,
        iterations: Int = 60
    ) -> Double {
        func bookSum(_ exponent: Double) -> Double {
            probabilities.reduce(0) { $0 + pow($1, exponent) }
        }

        guard bookSum(lowerBound) >= 1, bookSum(upperBound) <= 1 else { return 1 }

        var low = lowerBound
        var high = upperBound
        for _ in 0..<iterations {
            let mid = (low + high) / 2
            if bookSum(mid) > 1 { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// The book sum before de-vigging — 1.03 means a 3% overround. Surfaced for
    /// diagnostics: an implausible figure usually means the market was matched to
    /// the wrong race.
    public static func bookSum(_ raw: [Double?]) -> Double {
        raw.compactMap { $0 }.filter(\.isFinite).reduce(0, +)
    }
}
