# Fixtures

Provider payloads, used so the whole stack — parsing, matching, rating, tracking —
runs on Linux with no network and no credentials.

## Provenance

> ⚠️ The `racingapi-*.json` files are currently **hand-built from The Racing API's
> published OpenAPI schema**, not captured from a live response. They are faithful
> to the documented field names and types (including the spec's declaration of
> `ofr`, `lbs`, `draw`, `number` and `last_run` as `type: string`), and they
> deliberately include the awkward cases: numbers as strings *and* as numbers,
> blank strings, explicit nulls, missing keys, a jumps runner with no draw, an
> unraced horse with no form or rating, and a record with no `race_id`.
>
> **Replace them with real captures as soon as credentials are available.** A
> schema tells you the field names; only a real response tells you how a provider
> actually serialises them.

## Rules

**Strip credentials before committing anything here.** Betfair carries its session
token in the request rather than the response, but Racing API error bodies can echo
query parameters — check before adding.

Naming: `<provider>-<endpoint>-<description>.json`, e.g.
`racingapi-racecards-free.json`, `betfair-listmarketcatalogue-ascot.json`.

Files are copied into the test bundle by `Package.swift` (`.copy("Fixtures")`) and
loaded via `Fixture.data(_:)` in `FixtureLoading.swift`.
