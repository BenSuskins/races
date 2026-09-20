# Races — Developer Context

UK horse racing for iOS: browse **course → race → runner**, get an explainable
recommendation for each race, and track how well those recommendations actually do.

Native SwiftUI app plus a Foundation-only Swift package. **No backend** — the app
talks to two third-party providers directly and keeps its own history on device.

## Provider Reference

`docs/providers.md` is the canonical list of every third-party endpoint we call
(provider, tier required, rate limit, fields consumed, runnable `curl`).
**Whenever you add, remove, or change a provider call in
`ios/RacesKit/Sources/RacesKit/Providers/`, update `docs/providers.md` in the same
change.** Do not let it drift.

It matters more than a typical API doc: we don't own these APIs, and the free/paid
boundary is invisible until a 403 arrives at runtime.

## Layout

| Component | Directory | Description |
|-----------|-----------|-------------|
| Shared kit | `ios/RacesKit/` | Models, networking, matching, **the rating algorithm**, storage. Foundation-only so Linux CI tests it in seconds |
| iOS app | `ios/Races/` | SwiftUI client — views, view models, Keychain |

```
ios/RacesKit/Sources/RacesKit/
├── Core/          # ViewState, APIError, RetryPolicy, RateLimiter, HTTPClient
├── Models/        # Course, Race, Runner, RaceResult — provider-agnostic domain types
├── Providers/     # RacingAPI + Betfair clients behind two protocols
├── Matching/      # Joins the two providers' views of the same race
├── Rating/        # The algorithm: factors, weights, the rater
├── Tracking/      # Tip ledger, reconciliation, accuracy metrics
└── Store/         # Codable JSON on disk; the growing results archive
```

## Key Patterns

**Foundation-only kit** — no SwiftUI, no UIKit, **no Security.framework** in
`RacesKit`. The Linux CI job is what enforces this: it fails the moment a platform
framework is imported. Anything needing the Keychain lives in the app target
behind a protocol declared in `Core/`.

**Two provider protocols, not one** — `RacingDataProviding` (cards, results) and
`MarketDataProviding` (prices, SP). They are separate because either can be absent:
the user may not have configured Betfair, or a race may not match. Both absences are
normal states, never errors.

**Tier degradation is a feature** — `formHistory(horseID:)` throws
`APIError.tierUnavailable` on the free tier. The rater catches it and drops those
factors. `APIError.isExpectedLimitation` is what the UI keys off to show plain
information rather than an error banner. **Never** let a missing paid endpoint fail
a whole race.

**Everything the rater needs is pure** — the algorithm takes plain structs and
returns plain structs. No network, no clock, no disk. That is what lets the
back-test run on Linux in seconds, and it is a rule worth defending.

**Rate limiting** — each provider client owns a `RateLimiter`. The Racing API free
tier is 1 req/s. Always `await limiter.acquire()` before sending; `HTTPClient` does
this for you.

## Gotchas

- **The Racing API's endpoint names are inverted relative to its tiers.**
  `/v1/racecards/free` returns the *Basic* schema; `/v1/racecards/basic` returns the
  *full* one. Read the tier column in `docs/providers.md`, not the path.
- **UK form strings read right-to-left in time**: the *rightmost* character is the
  most recent run. `1-3241` means the last run was a 1st, not the first character.
- **Betfair runner names carry country suffixes** (`Kyprios (IRE)`) and sometimes a
  cloth-number prefix. Match on `CLOTH_NUMBER` against the Racing API's `number`
  first; names are the fallback, never the primary key.
- `.defaultIsolation(MainActor.self)` is set on the library target but **not** the
  test target — it would make `XCTestCase` subclasses MainActor-isolated, which
  cannot override the nonisolated `init(name:testClosure:)`.
- A `+` in a form-encoded body decodes as a space. `HTTPClient` percent-encodes it;
  Betfair passwords routinely contain one.

## Testing

- XCTest throughout, table-driven where it fits.
- Prefer fakes over mocks; fakes live in the test target alongside what they fake.
- Provider payloads are committed as fixtures under
  `ios/RacesKit/Tests/RacesKitTests/Fixtures/` and loaded via `Fixture.load(_:)`.
  **Strip credentials before committing a fixture.**
- The whole kit is testable with no network and no subscription. If a change can
  only be tested with live credentials, the seam is in the wrong place.

```bash
swift test --package-path ios/RacesKit          # the fast loop; also what CI runs first
swift test --package-path ios/RacesKit --filter BackTest
```

## Not betting advice

This is a personal tool for information only. Keep the disclaimer in Settings, and
keep the accuracy tracker honest — particularly the favourite benchmark, which is
what stops the model flattering itself.
