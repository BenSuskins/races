import XCTest
@testable import Races
import RacesKit

/// Tips reads what the server rated and sealed. Every test is
/// `@MainActor async`; see the gotcha in CLAUDE.md.
final class TipsViewModelTests: XCTestCase {

    /// Every fixture off time sits in 1970, so the injected clock — not the
    /// real one — decides what has run.
    private let now = Date(timeIntervalSince1970: 10_000)

    private func race(_ id: String, off: TimeInterval?) -> Race {
        .fixture(
            id: id,
            offDateTime: off.map { Date(timeIntervalSince1970: $0) },
            runners: [
                .fixture(id: "\(id)_a", name: "Alpha", clothNumber: 1, officialRating: 95, form: "111"),
                .fixture(id: "\(id)_b", name: "Bravo", clothNumber: 2, officialRating: 80, form: "543"),
            ])
    }

    @MainActor
    private func makeModel(_ card: ServerRacecard) -> (TipsViewModel, FakeRacesServer) {
        let server = FakeRacesServer(racecards: [.today: .success(card)])
        let loader = RacecardLoader(link: ServerLink(server: server), store: RacesStore(documents: InMemoryDocumentStore()))
        return (TipsViewModel(loader: loader, now: { self.now }), server)
    }

    @MainActor
    func test_onlyRacesStillToRunAreShownInOffTimeOrder() async throws {
        let card = ServerRacecard.fixture(races: [
            race("later", off: 30_000),
            race("gone", off: 5_000),
            race("sooner", off: 20_000),
        ])
        let (model, _) = makeModel(card)

        await model.load()

        XCTAssertEqual(try XCTUnwrap(model.state.value).map(\.id), ["sooner", "later"])
    }

    @MainActor
    func test_theSealIsTheServersNotThePhones() async throws {
        let card = ServerRacecard.fixture(races: [race("r1", off: 20_000), race("r2", off: 30_000)], sealed: ["r1"])
        let (model, _) = makeModel(card)

        await model.load()

        let selections = try XCTUnwrap(model.state.value)
        XCTAssertEqual(selections.first { $0.id == "r1" }?.isSealed, true)
        XCTAssertEqual(selections.first { $0.id == "r2" }?.isSealed, false)
    }

    @MainActor
    func test_coverageCountsRacesWithPricesNotRacesWithAMarket() async throws {
        let priced = race("priced", off: 20_000)
        let market = MarketSnapshot(prices: ["priced_a": RunnerPrice(backPrice: 2), "priced_b": RunnerPrice(backPrice: 3)])
        let card = ServerRacecard.fixture(races: [priced, race("formOnly", off: 30_000)], market: ["priced": market])
        let (model, _) = makeModel(card)

        await model.load()

        XCTAssertEqual(model.marketCoverage, TipsViewModel.MarketCoverage(pricedRaces: 1, totalRaces: 2))
    }

    @MainActor
    func test_theArchiveCountComesFromTheServer() async throws {
        let (model, _) = makeModel(.fixture(races: [race("r1", off: 20_000)], archivedRaces: 42))

        await model.load()

        XCTAssertEqual(model.archivedRaceCount, 42)
    }

    @MainActor
    func test_theScreenNeverRecordsAnything() async throws {
        let (model, server) = makeModel(.fixture(races: [race("r1", off: 20_000)]))

        await model.load()

        XCTAssertTrue(server.jobs.isEmpty)
        XCTAssertTrue(server.uploads.isEmpty)
    }
}
