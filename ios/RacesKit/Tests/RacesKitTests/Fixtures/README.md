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

## Capturing real ones

`scripts/capture-fixtures.py` pulls a card, its results and the corresponding
Betfair catalogue, redacts credentials, and writes them here. It needs live
credentials and cannot be run from a Claude session — both providers sit outside
that environment's network policy.

```bash
export RACING_USER=...  RACING_PASS=...
export BF_APP_KEY=...   BF_USER=...  BF_PASS=...

python3 scripts/capture-fixtures.py --self-test   # no credentials needed
python3 scripts/capture-fixtures.py --dry-run     # fetch, redact, write nothing
python3 scripts/capture-fixtures.py
```

Captured files carry a `-YYYYMMDD` suffix and arrive with a
`capture-manifest-YYYYMMDD.json` recording when they were taken. **The pairing is
the point**: the card and the catalogue come from the same London day, minutes
apart, which is the only way `RaceMatcher` can be tested against two real views
of the same races rather than against races invented to pass it.

The hand-built files below are **not** superseded by a capture. They carry the
awkward cases deliberately — numbers as strings and as numbers, blank strings,
explicit nulls, missing keys — and a real card will not reliably contain all of
them on any given afternoon. Keep both.

## Rules

**Strip credentials before committing anything here.** Betfair carries its session
token in the request rather than the response, but Racing API error bodies can echo
query parameters — check before adding.

Naming: `<provider>-<endpoint>-<description>.json`, e.g.
`racingapi-racecards-free.json`, `betfair-listmarketcatalogue-ascot.json`.

Files are copied into the test bundle by `Package.swift` (`.copy("Fixtures")`) and
loaded via `Fixture.data(_:)` in `FixtureLoading.swift`.
