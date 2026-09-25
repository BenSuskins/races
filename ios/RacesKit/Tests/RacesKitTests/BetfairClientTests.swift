import XCTest
@testable import RacesKit

final class BetfairClientTests: XCTestCase {

    private let credentials = BetfairCredentials(
        appKey: "APPKEY", username: "ben", password: "secret")
    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    /// A client whose session already holds a token, so tests of the betting
    /// calls do not have to script a login every time.
    private func makeClient(_ transport: FakeHTTPTransport) async -> BetfairClient {
        let session = BetfairSession(
            credentials: credentials, transport: transport, requestsPerSecond: 1000)
        await session.adopt(BetfairSessionToken(token: "TOKEN", obtainedAt: fixedNow))
        // Hoisted: capturing `self.fixedNow` would capture a non-Sendable
        // XCTestCase inside a @Sendable closure. `Date` is Sendable, so the
        // value can cross but the test case cannot.
        let now = fixedNow
        return BetfairClient(
            credentials: credentials,
            session: session,
            transport: transport,
            requestsPerSecond: 1000,
            now: { now })
    }

    // MARK: - Catalogue

    func test_marketsMapIntoExchangeMarkets() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-listmarketcatalogue.json"))
        let client = await makeClient(transport)

        let markets = try await client.markets(day: .today, countries: ["GB", "IE"])

        // Three in the fixture, but one has no start time and is dropped.
        XCTAssertEqual(markets.map(\.id), ["1.245678901", "1.245678902"])
        XCTAssertEqual(markets.first?.venue, "Ascot")
        XCTAssertEqual(markets.first?.marketName, "2m Hcap Chs")
    }

    func test_aMarketWithNoStartTimeIsRefusedRatherThanMatchedOnVenueAlone() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-listmarketcatalogue.json"))
        let client = await makeClient(transport)

        let markets = try await client.markets(day: .today, countries: ["GB"])

        // The ±6 minute window is half the matcher's evidence. Without a start
        // time a market could be joined to whatever else is running at that
        // course, which is the worst thing this layer can do.
        XCTAssertFalse(markets.contains { $0.venue == "Nowhere" })
    }

    func test_bothHeadersAreSentOnABettingCall() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-listmarketcatalogue.json"))
        let client = await makeClient(transport)

        _ = try await client.markets(day: .today, countries: ["GB"])

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Application"), "APPKEY")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Authentication"), "TOKEN")
    }

    func test_theFilterAsksForHorseRacingWinMarketsInTheRequestedCountries() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-listmarketcatalogue.json"))
        let client = await makeClient(transport)

        _ = try await client.markets(day: .today, countries: ["GB", "IE"])

        let body = try XCTUnwrap(transport.bodyString(at: 0))
        XCTAssertTrue(body.contains("\"7\""), "Horse Racing event type")
        XCTAssertTrue(body.contains("WIN"))
        XCTAssertTrue(body.contains("GB"))
        XCTAssertTrue(body.contains("IE"))
        // Without RUNNER_METADATA there is no CLOTH_NUMBER, and the matcher is
        // reduced to names.
        XCTAssertTrue(body.contains("RUNNER_METADATA"))
    }

    func test_todayAndTomorrowAskForDifferentWindows() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-listmarketcatalogue.json"))
        transport.enqueueJSON(try Fixture.string("betfair-listmarketcatalogue.json"))
        let client = await makeClient(transport)

        _ = try await client.markets(day: .today, countries: ["GB"])
        _ = try await client.markets(day: .tomorrow, countries: ["GB"])

        let first = try XCTUnwrap(transport.bodyString(at: 0))
        let second = try XCTUnwrap(transport.bodyString(at: 1))
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Prices

    func test_pricesMapBestBackAndLay() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-listmarketbook.json"))
        let client = await makeClient(transport)

        let books = try await client.prices(marketIDs: ["1.245678901"])

        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(book.marketID, "1.245678901")
        XCTAssertTrue(book.isOpen)
        XCTAssertTrue(book.isDelayed, "The free app key is always delayed")

        let favourite = try XCTUnwrap(book.prices[12345678])
        // Betfair orders the ladder best-first, so the first entry is the one
        // to take. `max` would be wrong on the lay side.
        XCTAssertEqual(try XCTUnwrap(favourite.backPrice), 2.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(favourite.layPrice), 2.46, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(favourite.lastTraded), 2.42, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(favourite.forecastPrice), 2.44, accuracy: 0.0001)
    }

    func test_aRemovedRunnerIsMarkedInactive() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-listmarketbook.json"))
        let client = await makeClient(transport)

        let books = try await client.prices(marketIDs: ["1.245678901"])

        let removed = try XCTUnwrap(books.first?.prices[32345678])
        XCTAssertFalse(removed.isActive)
        XCTAssertFalse(removed.hasAnyPrice, "A withdrawn runner must not be de-vigged with the rest")
    }

    func test_marketsAreBatchedAtBetfairsHardCap() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON("[]")
        transport.enqueueJSON("[]")
        let client = await makeClient(transport)

        let ids = (1...41).map { "1.\($0)" }
        _ = try await client.prices(marketIDs: ids)

        // 41 ids cannot go in one call: listMarketBook refuses more than 40.
        XCTAssertEqual(transport.requests.count, 2)
    }

    func test_duplicateMarketIDsAreNotRequestedTwice() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON("[]")
        let client = await makeClient(transport)

        _ = try await client.prices(marketIDs: ["1.1", "1.1", "1.2"])

        let body = try XCTUnwrap(transport.bodyString(at: 0))
        XCTAssertEqual(body.components(separatedBy: "1.1").count - 1, 1)
    }

    func test_noMarketIDsMeansNoRequest() async throws {
        let transport = FakeHTTPTransport()
        let client = await makeClient(transport)

        let books = try await client.prices(marketIDs: [])

        XCTAssertTrue(books.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - Faults

    func test_tooMuchDataSplitsTheBatchRatherThanFailing() async throws {
        let transport = FakeHTTPTransport()
        // First attempt refused, then each half succeeds.
        transport.enqueueJSON(try Fixture.string("betfair-apingexception-toomuchdata.json"))
        transport.enqueueJSON(try Fixture.string("betfair-listmarketbook.json"))
        transport.enqueueJSON("[]")
        let client = await makeClient(transport)

        let books = try await client.prices(marketIDs: ["1.1", "1.2", "1.3", "1.4"])

        // TOO_MUCH_DATA is an instruction, not a failure: the same markets come
        // back when asked for in smaller groups.
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(books.count, 1)
    }

    func test_anExpiredSessionIsReAuthenticatedOnceAndTheCallRetried() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-apingexception-session.json"))
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        transport.enqueueJSON(try Fixture.string("betfair-listmarketcatalogue.json"))
        let client = await makeClient(transport)

        let markets = try await client.markets(day: .today, countries: ["GB"])

        XCTAssertEqual(markets.count, 2, "A session can lapse mid-afternoon through no fault of ours")
        XCTAssertEqual(transport.requests.count, 3)
    }

    func test_aSecondSessionFailureIsSurfacedRatherThanLoopingForever() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-apingexception-session.json"))
        transport.enqueueJSON(try Fixture.string("betfair-login-success.json"))
        transport.enqueueJSON(try Fixture.string("betfair-apingexception-session.json"))
        let client = await makeClient(transport)

        do {
            _ = try await client.markets(day: .today, countries: ["GB"])
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(APIError.from(error), .unauthorized)
        }
        XCTAssertEqual(transport.requests.count, 3, "Exactly one retry, not a loop")
    }

    func test_aFaultOnATwoHundredIsNotReadAsAnEmptyResult() async throws {
        // The trap this whole layer exists for. Betfair returns faults with a
        // 200 as readily as with a 400, and an empty result looks exactly like
        // "no racing today".
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(
            #"{"detail":{"APINGException":{"errorCode":"INVALID_APP_KEY"}}}"#, status: 200)
        let client = await makeClient(transport)

        do {
            _ = try await client.markets(day: .today, countries: ["GB"])
            XCTFail("Expected forbidden, not an empty list")
        } catch {
            XCTAssertEqual(APIError.from(error), .forbidden)
        }
    }

    func test_aCatalogueWeCannotReadNamesTheFieldRatherThanOurSecondGuess() async throws {
        // `BetfairRawResponse` tries the array, then the fault envelope. The
        // envelope cannot decode from an array either, so reporting *its*
        // complaint — "expected a dictionary, found an array" — describes our
        // own fallback and hides the finding. The array's error names the field.
        //
        // This is not hypothetical. A 418KB catalogue that would not decode
        // reported exactly that, and the real cause was one value some way down
        // the payload. Nothing in the message could point at it.
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(#"""
        [{"marketId":"1.262709800","marketName":"1m2f Mdn Stks","runners":[
            {"selectionId":102146666},
            {"selectionId":null}
        ]}]
        """#)
        let client = await makeClient(transport)

        do {
            _ = try await client.markets(day: .today, countries: ["GB"])
            XCTFail("Expected the decode to fail")
        } catch {
            guard case .decoding(let reported) = APIError.from(error) else {
                return XCTFail("Expected decoding, got \(APIError.from(error))")
            }
            let shape = try XCTUnwrap(reported)
            let failure = try XCTUnwrap(
                shape.failure, "A decode failure with no coding path is the bug this fixes")
            XCTAssertEqual(failure.path, "[0].runners[1].selectionId")
            // And the message the user reads says so, which is the point.
            XCTAssertTrue(
                shape.description.contains("[0].runners[1].selectionId"),
                shape.description)
            XCTAssertFalse(
                shape.description.lowercased().contains("dictionary"),
                "That would be the envelope's complaint, not the payload's: \(shape.description)")
        }
    }

    func test_anUnknownFaultCodeIsCarriedThroughRatherThanSwallowed() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(
            #"{"detail":{"APINGException":{"errorCode":"SOMETHING_NEW"}}}"#)
        let client = await makeClient(transport)

        do {
            _ = try await client.markets(day: .today, countries: ["GB"])
            XCTFail("Expected a badRequest carrying the code")
        } catch {
            guard case .badRequest(let message) = APIError.from(error) else {
                return XCTFail("Expected badRequest, got \(APIError.from(error))")
            }
            XCTAssertTrue(
                try XCTUnwrap(message).contains("SOMETHING_NEW"),
                "An unrecognised code is the interesting case; don't collapse it")
        }
    }

    // MARK: - Starting prices

    func test_startingPricesAreReadOnceTheMarketHasSettled() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-listmarketbook-settled.json"))
        let client = await makeClient(transport)

        let prices = try await client.startingPrices(marketIDs: ["1.245678901"])

        let market = try XCTUnwrap(prices["1.245678901"])
        XCTAssertEqual(try XCTUnwrap(market[12345678]), 2.64, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(market[22345678]), 5.2, accuracy: 0.0001)
    }

    func test_anAbsentOrZeroStartingPriceIsOmittedNotDefaulted() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON(try Fixture.string("betfair-listmarketbook-settled.json"))
        let client = await makeClient(transport)

        let prices = try await client.startingPrices(marketIDs: ["1.245678901"])
        let market = try XCTUnwrap(prices["1.245678901"])

        // A zero would read as a starting price of nothing and wreck the ROI
        // figure; a missing one means the race has not settled.
        XCTAssertNil(market[32345678], "Removed runner, SP of 0")
        XCTAssertNil(market[42345678], "No actualSP at all")
    }

    func test_startingPricesAskForSPTraded() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueueJSON("[]")
        let client = await makeClient(transport)

        _ = try await client.startingPrices(marketIDs: ["1.1"])

        let body = try XCTUnwrap(transport.bodyString(at: 0))
        XCTAssertTrue(body.contains("SP_TRADED"))
    }
}
