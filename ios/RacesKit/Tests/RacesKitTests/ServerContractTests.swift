import XCTest
@testable import RacesKit

/// The app decodes the server's responses with its own Codable models, so the
/// two have to agree about every key and every enum shape.
///
/// The `server-*.json` fixtures are real responses, written by the server's
/// `TestContractFixtures` (`go test ./internal/api -update`) and compared
/// byte for byte on every Go run. This decodes each one here. If the server
/// changes a shape, the Go test fails until the fixture is regenerated, and
/// then this fails until the app can read it.
final class ServerContractTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try Fixture.decode(type, from: name, using: RacesServerClient.decoder)
    }

    func test_theRacecardDecodesIntoTheKitsOwnModels() throws {
        let card = try decode(ServerRacecard.self, "server-racecard.json")
        XCTAssertEqual(card.day, .today)
        XCTAssertEqual(card.date, "2026-09-20")
        XCTAssertEqual(card.races.count, 2)
        let ascot = try XCTUnwrap(card.races.first { $0.id == "rac_1001" })
        XCTAssertEqual(ascot.ratingBand, 0...95)
        XCTAssertEqual(ascot.going, .goodToFirm)
        XCTAssertNotNil(ascot.offDateTime)

        let assessment = try XCTUnwrap(card.assessments["rac_1001"])
        XCTAssertEqual(assessment.runners.count, 4)
        XCTAssertTrue(assessment.isFormOnly, "the fixture server has no Betfair")
        XCTAssertNotNil(assessment.selection)

        let tip = try XCTUnwrap(card.tips["rac_1001"])
        XCTAssertEqual(tip.weightsID, "v3")
        XCTAssertFalse(tip.contributions.isEmpty)
        XCTAssertEqual(
            tip.contributions.first { $0.factor == .draw }?.availability,
            .notApplicable("no draw-bias data for this course yet"))

        let wetherby = try XCTUnwrap(card.results["rac_1002"])
        XCTAssertEqual(wetherby.finisher(horseID: "hrs_5")?.position, .pulledUp)
        XCTAssertEqual(wetherby.winner?.horseID, "hrs_6")
    }

    func test_theRaceDetailDecodes() throws {
        let detail = try decode(ServerRaceDetail.self, "server-race.json")
        XCTAssertEqual(detail.race.id, "rac_1001")
        XCTAssertNotNil(detail.assessment)
        XCTAssertNotNil(detail.tip)
        XCTAssertNotNil(detail.result)
    }

    func test_theRecordDecodesIntoAnAccuracyReport() throws {
        let record = try decode(ServerRecord.self, "server-record.json")
        XCTAssertEqual(record.weightsID, record.activeWeightsID)
        XCTAssertEqual(record.sources["server"], 2)
        XCTAssertEqual(record.report.total, 2)
        XCTAssertEqual(record.report.pending, 2)
        XCTAssertEqual(record.report.benchmarkedModel?.settled, record.report.favouriteBaseline.settled)
        XCTAssertNil(record.report.modelWilson)
        XCTAssertNil(record.report.favouriteWilson)
    }

    func test_theModelDecodesIntoRatingWeights() throws {
        let model = try decode(ServerModel.self, "server-model.json")
        XCTAssertEqual(model.active, .v3, "the server's v3 is the kit's v3, number for number")
        XCTAssertEqual(model.modelVersion, RaceRater.modelVersion)
        XCTAssertTrue(model.weights.contains { $0.weights.id == "market-only" && $0.origin == "preset" })
        XCTAssertTrue(model.weights.contains { $0.origin == "device" })
    }

    func test_theStatusDecodes() throws {
        let status = try decode(ServerStatus.self, "server-status.json")
        XCTAssertTrue(status.racingAPI.configured)
        XCTAssertFalse(status.betfair.configured)
        XCTAssertFalse(status.jobs.isEmpty)
        XCTAssertEqual(status.activeWeightsID, "v3")
    }

    func test_coursesDecode() throws {
        let courses = try Fixture.data("server-courses.json")
        XCTAssertFalse(courses.isEmpty)
    }

    // MARK: - Client

    func test_everyCallCarriesTheBearerToken() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("server-status.json"))
        let client = RacesServerClient(
            configuration: ServerConfiguration(baseURL: URL(string: "https://races.example")!, token: "secret-token"),
            transport: transport)
        _ = try await client.status()
        XCTAssertEqual(transport.authorizationHeader(), "Bearer secret-token")
        XCTAssertEqual(transport.lastRequest?.url?.absoluteString, "https://races.example/v1/status")
    }

    func test_theRacecardAsksForTheDay() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("server-racecard.json"))
        let client = RacesServerClient(
            configuration: ServerConfiguration(baseURL: URL(string: "https://races.example")!, token: "t"),
            transport: transport)
        _ = try await client.racecard(day: .tomorrow)
        XCTAssertEqual(transport.lastRequest?.url?.query, "day=tomorrow")
    }

    func test_aRefusedTokenIsUnauthorized() async {
        let transport = FakeHTTPTransport()
        transport.enqueueStatus(401, body: #"{"error":"unauthorized"}"#)
        let client = RacesServerClient(
            configuration: ServerConfiguration(baseURL: URL(string: "https://races.example")!, token: "wrong"),
            transport: transport)
        do {
            _ = try await client.status()
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(APIError.from(error), .unauthorized)
        }
    }

    // MARK: - Configuration

    func test_aTokenIsWhatMakesTheServerConfigured() throws {
        final class Store: CredentialsStoring, @unchecked Sendable {
            var slots: [CredentialSlot: String] = [:]
            func read(_ slot: CredentialSlot) throws -> String? { slots[slot] }
            func write(_ value: String?, to slot: CredentialSlot) throws { slots[slot] = value }
            func removeAll() throws { slots = [:] }
        }
        let store = Store()
        XCTAssertNil(try ServerConfiguration(reading: store))

        store.slots[.serverToken] = "  token  "
        let defaulted = try XCTUnwrap(ServerConfiguration(reading: store))
        XCTAssertEqual(defaulted.baseURL, ServerConfiguration.defaultBaseURL)
        XCTAssertEqual(defaulted.token, "token")

        store.slots[.serverURL] = "http://192.168.0.202:8790"
        XCTAssertEqual(try ServerConfiguration(reading: store)?.baseURL.absoluteString, "http://192.168.0.202:8790")

        store.slots[.serverURL] = "not a url"
        XCTAssertEqual(try ServerConfiguration(reading: store)?.baseURL, ServerConfiguration.defaultBaseURL)
    }
}
