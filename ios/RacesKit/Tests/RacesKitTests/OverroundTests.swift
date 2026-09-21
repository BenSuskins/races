import XCTest
@testable import RacesKit

final class OverroundTests: XCTestCase {

    // MARK: - Implied probability

    func test_usesTheMidOfBackAndLayWhenTheSpreadIsSane() throws {
        let price = RunnerPrice(backPrice: 2.0, layPrice: 2.1)
        let implied = try XCTUnwrap(Overround.impliedProbability(price))

        XCTAssertEqual(implied, (0.5 + 1 / 2.1) / 2, accuracy: 0.000001)
    }

    /// A yawning spread means the market has not settled, and its midpoint is
    /// meaningless. Fall back to the back price rather than averaging noise.
    func test_fallsBackToTheBackPriceWhenTheSpreadIsWide() throws {
        let price = RunnerPrice(backPrice: 2.0, layPrice: 10.0)
        XCTAssertEqual(try XCTUnwrap(Overround.impliedProbability(price)), 0.5, accuracy: 0.000001)
    }

    func test_fallsBackThroughLastTradedThenForecast() throws {
        let traded = RunnerPrice(lastTraded: 4.0)
        XCTAssertEqual(try XCTUnwrap(Overround.impliedProbability(traded)), 0.25, accuracy: 0.000001)

        let forecast = RunnerPrice(forecastPrice: 5.0)
        XCTAssertEqual(try XCTUnwrap(Overround.impliedProbability(forecast)), 0.2, accuracy: 0.000001)
    }

    /// Tomorrow's markets have little or no liquidity, so the forecast price is
    /// often the only anchor a card has before it starts trading.
    func test_forecastIsUsedWhenNothingElseExists() {
        XCTAssertNotNil(Overround.impliedProbability(RunnerPrice(forecastPrice: 3.0)))
    }

    /// Withdrawn runners are excluded from the book entirely rather than de-vigged
    /// alongside everyone else.
    func test_withdrawnRunnersHaveNoProbability() {
        let price = RunnerPrice(backPrice: 2.0, isActive: false)
        XCTAssertNil(Overround.impliedProbability(price))
    }

    func test_noPriceMeansNoProbability() {
        XCTAssertNil(Overround.impliedProbability(RunnerPrice()))
    }

    func test_nonsensicalPricesAreRejected() {
        XCTAssertNil(Overround.impliedProbability(RunnerPrice(backPrice: 1.0)))
        XCTAssertNil(Overround.impliedProbability(RunnerPrice(backPrice: 0)))
        XCTAssertNil(Overround.impliedProbability(RunnerPrice(backPrice: -2)))
    }

    // MARK: - Normalising

    func test_proportionalNormalisationSumsToOne() throws {
        let raw: [Double?] = [0.5, 0.35, 0.2]
        let normalised = Overround.normalise(raw, method: .proportional)

        XCTAssertEqual(normalised.compactMap { $0 }.reduce(0, +), 1.0, accuracy: 0.000001)
    }

    func test_proportionalNormalisationPreservesRatios() throws {
        let normalised = Overround.normalise([0.6, 0.3, 0.3], method: .proportional)
        let first = try XCTUnwrap(normalised[0])
        let second = try XCTUnwrap(normalised[1])

        XCTAssertEqual(first / second, 2.0, accuracy: 0.000001)
    }

    func test_unpricedRunnersStayUnpriced() {
        let normalised = Overround.normalise([0.5, nil, 0.4], method: .proportional)
        XCTAssertNil(normalised[1])
        XCTAssertEqual(normalised.compactMap { $0 }.reduce(0, +), 1.0, accuracy: 0.000001)
    }

    func test_powerNormalisationAlsoSumsToOne() {
        let normalised = Overround.normalise([0.5, 0.35, 0.2, 0.1], method: .power)
        XCTAssertEqual(normalised.compactMap { $0 }.reduce(0, +), 1.0, accuracy: 0.000001)
    }

    /// The point of the power method: the overround is not spread evenly, so
    /// correcting it proportionally over-prices the outsiders. Both methods agree
    /// about who the favourite is; they differ most at the bottom of the book.
    func test_theTwoMethodsDifferMostAtLongOdds() throws {
        let raw: [Double?] = [0.5, 0.3, 0.15, 0.08]

        let proportional = Overround.normalise(raw, method: .proportional).compactMap { $0 }
        let power = Overround.normalise(raw, method: .power).compactMap { $0 }

        XCTAssertEqual(proportional.firstIndex(of: proportional.max() ?? 0), 0)
        XCTAssertEqual(power.firstIndex(of: power.max() ?? 0), 0)
        XCTAssertNotEqual(proportional.last, power.last)
    }

    func test_emptyOrUnpricedBookYieldsNothing() {
        XCTAssertTrue(Overround.normalise([], method: .proportional).isEmpty)
        XCTAssertEqual(Overround.normalise([nil, nil], method: .proportional).compactMap { $0 }.count, 0)
    }

    // MARK: - Power exponent

    func test_powerExponentSolvesTheBook() {
        let probabilities = [0.5, 0.3, 0.15, 0.1]
        let k = Overround.powerExponent(probabilities)
        let sum = probabilities.reduce(0) { $0 + pow($1, k) }

        XCTAssertEqual(sum, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(k, 1.0, "an overround book needs an exponent above 1")
    }

    /// An unbracketed root means falling back to proportional rather than
    /// inventing an exponent.
    func test_powerExponentFallsBackToOneWhenUnsolvable() {
        XCTAssertEqual(Overround.powerExponent([0.1, 0.1]), 1.0)
    }

    // MARK: - Diagnostics

    func test_bookSumReportsTheOverround() {
        XCTAssertEqual(Overround.bookSum([0.5, 0.35, 0.18]), 1.03, accuracy: 0.000001)
        XCTAssertEqual(Overround.bookSum([0.5, nil, 0.5]), 1.0, accuracy: 0.000001)
    }
}
