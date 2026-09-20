# Fixtures

Recorded JSON payloads from the two providers, used so the whole stack — parsing,
matching, rating, tracking — runs on Linux with no network and no credentials.

**Strip credentials before committing anything here.** Betfair responses carry a
session token in the request, not the response, but Racing API error bodies can
echo query parameters, so check before adding.

Naming: `<provider>-<endpoint>-<description>.json`, e.g.
`racingapi-racecards-free-2026-09-20.json`, `betfair-listmarketcatalogue-ascot.json`.

Files here are copied into the test bundle by `Package.swift` (`.copy("Fixtures")`)
and loaded via `Fixture.load(_:)` in `FixtureLoading.swift`.
