# Races — Developer Context

UK horse racing for iOS: browse **course → race → runner**, get an explainable
recommendation for each race, and track how well those recommendations actually do.

Three parts:

- **`server/`** — a Go backend with one SQLite file, deployed as a container on
  the homelab `docker` host and reached at `https://races-api.suskins.co.uk` over
  the LAN and Tailscale. It owns the two providers, the rater, the sealing rule,
  settlement, the accuracy record, retraining and back-tests. **It is where the
  history lives**, and it keeps every raw provider payload.
- **`ios/RacesKit/`** — a Foundation-only Swift package: the domain models the
  app decodes the server's JSON into, the server client, and — until it is
  deleted — the Swift rater the Go one was ported from.
- **`ios/Races/`** — a SwiftUI client that *reads*. It holds the server's
  address and an API token, and nothing it does can change the record.

Single user, several phones: every app talks to the same server with the same
token. `server/README.md` has the API, the timetable and the configuration.

## What is left

`docs/roadmap.md` is the current backlog: what remains, who owns each item (some
need a device, real credentials or a billing decision rather than a commit), and
the dependencies between them. It also records the live blockers, which are not
work items: the Actions quota, the absence of any backup of `races.db`, and the
fact that `RacesKitTests` is absent from `Races.xcscheme` so the kit's tests are
covered only by the Linux job.

## Provider Reference

`docs/providers.md` is the canonical list of every third-party endpoint we call
(provider, tier required, rate limit, schedule, fields consumed, runnable `curl`).
**Whenever you add, remove, or change a provider call in
`server/internal/racingapi/` or `server/internal/betfair/`, update
`docs/providers.md` in the same change.** Do not let it drift.

It matters more than a typical API doc: we don't own these APIs, and the free/paid
boundary is invisible until a 403 arrives at runtime.

## Layout

| Component | Directory | Description |
|-----------|-----------|-------------|
| Server | `server/` | Go 1.25, `modernc.org/sqlite` (no cgo). Providers, matching, **the rating algorithm**, tracking, training, back-test, HTTP API |
| Shared kit | `ios/RacesKit/` | Models, the server client, and the Swift rater kept for parity. Foundation-only so Linux CI tests it in seconds |
| iOS app | `ios/Races/` | SwiftUI client — views, view models, Keychain |

```
server/
├── cmd/races-server/   # Env config, wiring, HTTP server, scheduler
└── internal/
    ├── domain/         # Race, Runner, RaceResult… in RacesKit's Codable JSON shape
    ├── rating/         # Port of RacesKit/Rating — factors, form, overround, rater
    ├── training/       # Nightly re-fit, promoted only on held-out improvement
    ├── tracking/       # Tips, sealing rule, settlement, accuracy, strike-rate archive
    ├── matching/       # Normalisers, runner and race matchers
    ├── httpx/          # Rate limiter, retry, status mapping, response shapes
    ├── racingapi/      # The Racing API client
    ├── betfair/        # Session (login, latch, keep-alive), client, faults
    ├── store/          # SQLite; migrations embedded
    ├── service/        # The jobs and the timetable
    ├── importer/       # A phone's pre-server documents → the database
    ├── backtest/       # Any weights, over history, against the market
    ├── api/            # HTTP; bearer token on /v1
    └── parity/         # Golden file pinning Go to Swift
```

### App targets

| Target | Directory | Notes |
|--------|-----------|-------|
| `Races` | `ios/Races/Races/` | The app. Folder-synced group, so new files need no project edit |
| `RacesTests` | `ios/Races/RacesTests/` | Unit tests hosted by the app, for what cannot live in the kit |

```
ios/Races/Races/
├── App/           # AppEnvironment + ServerLink, RacesStore (cache) + LegacyHistory, RacecardLoader
├── Components/    # StateContentView, ErrorStateView, RaceRow
├── Today/         # Today's and tomorrow's meetings
├── Tips/          # The model's selection per race
├── Courses/       # Every course, searchable — pushed from Racing, not a tab
├── Model/         # The algorithm on screen: the server's active weights
├── Race/          # Race card, runner detail, the factor breakdown
├── Record/        # Strike rate, favourite baseline, coverage
├── Settings/      # Server address and token, connection test, history upload
└── Credentials/   # KeychainCredentialsStore
```

The app's state is carried by a few types, each with one job:

- **`AppEnvironment`** — the only place that decides whether the server exists.
  It reads the address and token from the Keychain and puts a client — or the
  reason there is none — into the `ServerLink`.
- **`ServerLink`** — one long-lived object every view model holds. Its server is
  swapped in place by `AppEnvironment.refresh()`, never replaced, so a screen
  built before the token was entered sees the server without a relaunch (see the
  gotcha below). `require()` returns the server or throws the reason.
- **`RacecardLoader`** — reads a day's card from the server, shared by Racing,
  Tips and Courses so they cannot disagree and opening all three costs one
  request. Falls back to the last card saved on disk when the server is out of
  reach, and says so.
- **`RacesStore`** — an `actor` holding the last card and record on disk. A cache,
  never authoritative, never written back.
- **`LegacyHistory`** — the tip ledger, results archive and training state a
  phone wrote to Application Support before the server existed. Settings uploads
  them once (`POST /v1/import`); they are read, never modified.

Tabs are **Racing, Tips, Model, Record, Settings** — and five is the ceiling.
iOS collapses a sixth into a "More" list, which would bury Settings, where
the server is configured. So the course directory is **pushed from Racing**
rather than holding a tab: Racing's own search covers the meetings on today's
card, and the directory covers the courses with no fixture, which is the only
thing the card cannot tell you.

**The Model tab is read-only, and that is a constraint rather than an omission.**
`weightsID` is stamped onto every stored tip, so editing a weight without
changing the id silently invalidates the accuracy history. The server changes
weights only by minting a new id — nightly retraining, promoted only when the
candidate beats the current set on races it never saw — and `GET /v1/record?weightsID=`
keeps the populations apart. Trying a set without running it is what
`POST /v1/backtests` is for. The screen shows the server's active set: all
twelve factors including the four at zero, α and β, the clip, the coverage floor
and the form-scoring table.

**Prices are fetched before tips are sealed, never after.** The server's seal
job prices every race inside the five-minute window and stores that book as the
race's `seal` snapshot before rating it. A tip sealed form-only and re-rated
with prices afterwards would be a record of something nobody was shown.

**The server records the whole card, on a clock.** Every race is drafted every
fifteen minutes and sealed inside the window whether or not a phone is open. A
ledger of races someone happened to look at is a biased sample, and the
favourite baseline would be measured against a different population. The app
never records anything.

`Races.xcodeproj` is **checked in and was written by hand**, not generated by
Xcode — see the gotcha below. The macOS CI job is what validates it.

```
ios/RacesKit/Sources/RacesKit/
├── Core/          # ViewState, APIError, RetryPolicy, RateLimiter, HTTPClient, credentials
├── Server/        # RacesServing, RacesServerClient, the server's response types
├── Models/        # Course, Race, Runner, RaceResult — what the server's JSON decodes into
├── Rating/        # The Swift rater — kept for ServerParityTests until deleted
├── Tracking/      # TipRecord, AccuracyReport and the logic they came with
├── Providers/     # The old Swift provider clients — no longer on any request path
├── Matching/      # CourseNameNormaliser is still used by the course directory
└── Store/         # Codable JSON on disk
```

## Key Patterns

**Foundation-only kit** — no SwiftUI, no UIKit, **no Security.framework** in
`RacesKit`. The Linux CI job is what enforces this: it fails the moment a platform
framework is imported. Anything needing the Keychain lives in the app target
behind a protocol declared in `Core/`.

**The server speaks the kit's Codable.** Every response is the JSON shape
Swift's synthesised Codable produces for the matching RacesKit type: camelCase
keys, optionals omitted, enums with associated values as single-key objects
(`{"won":{"betfairSP":4.2}}`, `{"finished":{"_0":3}}`), `ClosedRange` as a pair,
and dates as whole-second UTC through `domain.Instant`. That is what lets the
app decode `Race`, `RaceAssessment`, `TipRecord` and `AccuracyReport` with the
models it already had, and what lets the server read a phone's uploaded ledger.
Two committed fixture sets hold it: `server-*.json` (real API responses,
decoded by `ServerContractTests`) and `server-golden-rating.json` (the Go rater's
numbers, matched by `ServerParityTests`). The Go tests compare both byte for
byte, so a shape change fails Go first; regenerate with `-update` and run the
Swift tests before merging.

**Two provider interfaces, not one** — `service.RacingData` (cards, results) and
`service.MarketData` (prices, SP). They are separate because either can be
absent: the server may have no Betfair credentials, or a race may not match.
Both absences are normal states, never errors.

`MarketData` returns `matching.ExchangePrices`, keyed by Betfair's own
**selection id** — deliberately not `MarketSnapshot`, which is keyed by *our*
horse id and can only exist after matching has joined the two providers. Handing
the rater exchange-keyed prices would mean it had to know two providers exist,
which is the thing the matching layer is for. `matching.Snapshot` is the one
place that crossing happens, and it **drops** unmatched selections rather than
guessing.

**`MarketReference` is the one exception, and it is deliberate.** Settlement is a
different job from rating: Betfair returns starting prices keyed by its own
selection ids, and by the time a race settles the catalogue that would let us
re-derive the mapping may be gone. So `matching.Match.Reference()` freezes
`marketID` plus the whole field's `horseID → selectionID` map onto the `TipRecord`
at the moment the match was made and believed. It stores the **whole field**, not
just the selection, because the favourite baseline needs a price too — priced tip
against priceless benchmark is the most flattering possible asymmetry. Keyed our
id → theirs so the stored ledger is a readable JSON object rather than a flat
alternating array.

**Tier degradation is a feature** — `racingapi.Client.FormHistory` returns
`TierUnavailable` on the free tier, and the first 403 latches so twenty runners
do not burn twenty rate-limit slots. **Never** let a missing paid endpoint fail a
whole race. On the app side `APIError.isExpectedLimitation` is still what keys
plain information ("not configured") rather than an error banner.

**Everything the rater needs is pure** — the algorithm takes plain structs and
returns plain structs. No network, no clock, no disk. That is what lets the
back-test replay history in seconds, and it is a rule worth defending.

**Rate limiting** — each provider client owns an `httpx.RateLimiter`. The Racing
API free tier is 1 req/s. `httpx.Client` waits on it before every send, and
retries only idempotent calls.

**One SQLite connection** — `store.Open` sets `MaxOpenConns(1)` and every job
runs under one mutex, so a seal and a results ingest can never interleave, which
is the job the `RacesStore` actor used to do. The consequence: inside
`Store.Tx`, use only the `Tx` methods. Calling a `Store` method from within the
transaction waits for the connection the transaction holds, forever.

**Matching refuses rather than guesses** — `docs/matching.md` has the design.
The rule that shapes it: a race with no market falls back to form only and says
so, while a race with the *wrong* market silently anchors every runner to another
race's prices and looks entirely normal. So ties, thin overlaps and ambiguity are
all refused, and every refusal carries a reason.

**Credentials cross the module boundary as a protocol** — `CredentialsStoring` and
`ServerConfiguration` live in the kit; `KeychainCredentialsStore` implements them
in the app. *Which* secrets count as configured is kit logic — a token makes the
server configured, a blank address means the default one — and therefore tested
on Linux; only the `SecItem*` calls are app-side. The five provider slots stay
in `CredentialSlot` so `removeAll()` still reaches anything a phone saved before
the server; saving the server clears them. The provider credentials themselves
live in Ansible Vault, and only the server sees them.

## Gotchas

- **The Racing API is inconsistent about JSON types, in both directions.** Its own
  spec declares `ofr`, `lbs`, `draw`, `number` and `last_run` as `type: string`,
  and they arrive both quoted and bare. `position` and `class` are declared
  strings and do the same. Decode numerics through `LenientNumber` and
  parsed text through `LenientText`; a bare `String?` or `Int?` will throw and
  discard the whole race.
- **The Racing API's endpoint names are inverted relative to its tiers.**
  `/v1/racecards/free` returns the *Basic* schema; `/v1/racecards/basic` returns the
  *full* one. Read the tier column in `docs/providers.md`, not the path.
- **UK form strings read right-to-left in time**: the *rightmost* character is the
  most recent run. `1-3241` means the last run was a 1st, not the first character.
- **Betfair runner names carry country suffixes** (`Kyprios (IRE)`) and sometimes a
  cloth-number prefix. Match on `CLOTH_NUMBER` against the Racing API's `number`
  first; names are the fallback, never the primary key.
- **That cloth-number rule is about runners within a race, never about which race
  a market is.** Every race numbers its runners from one, so cloths agree between
  any two races of the same size. `RaceMatcher` therefore scores candidate markets
  with `allowClothNumbers: false` and only enables them once the market is
  settled. Getting this the wrong way round gives a matcher that confidently
  prices every race off whatever market shares its course and time — it is the
  worst thing this component can do, and the easiest to write by accident.
  `test_clothNumbersAloneCannotIdentifyARace` exists to stop it coming back.
- **No course-normalisation rule is acceptable unless
  `test_noTwoRealCoursesShareAKey` still passes.** It runs every British and Irish
  course through `CourseNameNormaliser` and asserts the keys stay distinct. A rule
  that collapsed two real courses would price one meeting off another's market.
- **`.defaultIsolation(MainActor.self)` is set on neither target**, unlike Family
  Hub. This kit is mostly pure value types and a pure algorithm, so a MainActor
  default forces hundreds of isolated conformances to `Equatable`, `Codable` and
  `OptionSet` — enough of them to crash the compiler during module emission. The
  two types that need isolation declare it themselves: `RacingAPIClient` (it
  caches tier state) and `RateLimiter`. On the *test* target it is doubly wrong:
  it would make `XCTestCase` subclasses MainActor-isolated, and those cannot
  override the nonisolated `init(name:testClosure:)`.
- A `+` in a form-encoded body decodes as a space. `HTTPClient` percent-encodes it;
  Betfair passwords routinely contain one.
- **Betfair reports failure with HTTP 200.** A refused login comes back `200` with
  `status: "FAIL"` and the reason in `error`, so a status-code check reads it as a
  success that happens to have no token. Betting calls do the same with a
  `detail.APINGException.errorCode` envelope — and there the cost is worse,
  because an unhandled fault decodes as an **empty array**, which is
  indistinguishable from "no racing today". Every betting call therefore decodes
  the fault envelope speculatively; see `BetfairRawResponse`.
- **`TOO_MUCH_DATA` is an instruction, not an error.** The same markets come back
  if asked for in smaller groups, so `BetfairClient` halves the batch recursively
  rather than surfacing it. Mapping it to an `APIError` like the other codes would
  turn a recoverable condition into a card with no prices.
- **A `CLOTH_NUMBER` of `"0"` means "not published", not "number zero".** Betfair
  sends it on markets without published numbers, and cloth number is the
  matcher's *primary* join key — so treating it as real would join on a value
  every such runner shares. `BetfairMapping.clothNumber` requires `> 0`. All the
  metadata arrives as strings, including the numeric fields.
- **Betfair's price ladder is best-price-first**, so the best available is
  `.first`, never `max`. `max` happens to be right for backing and is wrong for
  laying, which is the sort of asymmetry that survives a casual read.
- **Betfair's session lifetime is still unmeasured**, and the client does not
  depend on it: it renews *reactively* when the exchange reports
  `INVALID_SESSION_INFORMATION`, retrying exactly once. A 2FA or certificate
  failure is **latched** instead, because retrying that on every card refresh
  would look like a hang and could lock the account.
- **`APIError.decoding` carries an `HTTPResponseShape?`, and the reason is that
  the bare case was unactionable.** "We received an unexpected response. Please
  try again." names no status, no content type and nothing about the body — so a
  failure that retrying cannot fix reads as one that might, and the user is sent
  back to re-type a password that was never checked. The payload is the status,
  the content type, the byte count and a whitespace-collapsed, token-redacted
  snippet, and `HTTPClient.decode` fills it in for **every** call, because the
  decode that fails is not always the one you expect. `Test Betfair` runs
  `markets(day:)`, which is a login *and* a catalogue fetch: fixing only the
  login left the same useless message coming from the second call, which is
  exactly what happened. Betfair's login has its own richer path on top —
  `BetfairLoginFailure.unreadableResponse(_:)` — because there the classification
  matters as well as the detail, and every field of `BetfairLoginResponse` is
  optional, so any JSON *object* decodes and a decode failure can only mean the
  reply was not JSON. Neither is latched: a jurisdiction block, a captive portal
  and a proxy all answer `200` with HTML, and unlike a 2FA challenge the cause is
  outside the account and may be gone by the next attempt. The Settings rows set
  `.textSelection(.enabled)`, since a diagnostic nobody can copy is a diagnostic
  nobody can report.
- **`Races.xcodeproj` was hand-written, so treat the macOS CI job as the thing
  that proves it works.** It uses `objectVersion = 77` with
  `PBXFileSystemSynchronizedRootGroup`, so adding a source file needs no project
  edit at all — drop it in `ios/Races/Races/` and it is in the target. Opening the
  project in Xcode and changing a setting will rewrite the file with Xcode's own
  UUIDs; that is fine and expected.
- **Never name a simulator model in a `-destination`.** `name=iPhone 16,OS=latest`
  looks like a pin on the project and is really a pin on the runner image's
  installed device list, which is not ours and changes without notice. It took
  `main` red the day it was added: the image that ran the merge commit had no
  iPhone 16, so `xcodebuild` could offer only its placeholder destinations. CI
  resolves a UDID at run time instead, and the step prints the installed runtimes
  and devices when it finds none.
- **`VERSIONING_SYSTEM = "apple-generic"` is set at project level and must stay.**
  Without it the `agvtool` call in `ci_scripts/ci_post_clone.sh` silently does
  nothing and every Xcode Cloud build ships the same build number. (An earlier
  version of this note claimed Family Hub has that bug. It does not: it has no
  `ci_scripts/` and no `agvtool` call at all, and sets
  `CURRENT_PROJECT_VERSION` by hand.)
- **Two TestFlight prerequisites live in the project and are easy to delete by
  accident.** `ITSAppUsesNonExemptEncryption = false` in
  `ios/Races/Races/Info.plist` is the export-compliance declaration — without it
  every upload sits at "Missing Compliance" until the questionnaire is answered
  by hand. And `AppIcon.appiconset` must contain a real 1024×1024 PNG **with no
  alpha channel**; App Store Connect rejects the marketing icon otherwise.
  `scripts/make-app-icon.py` regenerates the placeholder.
- **`Info.plist` needs its membership exception in the pbxproj.** It sits inside
  a folder-synced group, so without
  `PBXFileSystemSynchronizedBuildFileExceptionSet` listing it, the group copies
  it into the bundle as a resource and the build fails with "Multiple commands
  produce .../Info.plist" — the generated one against the copied one.
- **The app target defaults to MainActor isolation; the kit does not.** So a class
  in the app that conforms to a kit protocol with nonisolated requirements —
  `KeychainCredentialsStore` — must be declared `nonisolated`, or the conformance
  is MainActor-isolated and the kit cannot call it from off the main actor.
  **This has to hold all the way down.** Marking the outermost type is not
  enough: `KeychainOperating` and `SystemKeychain` inherited the MainActor default
  and produced six "call to main actor-isolated instance method in a synchronous
  nonisolated context" warnings, because every call through the seam was crossing
  an isolation boundary. Warnings in Swift 5 mode, errors under Swift 6. Any new
  app-side type that the kit calls into needs `nonisolated` on the type *and* on
  the protocol requirements it satisfies.
- **The same default breaks app-side types whose conformances are used
  generically.** The app target enables `InferIsolatedConformances`, so a type
  declared there gets a *main-actor-isolated* `Equatable`/`Hashable` conformance,
  and an isolated conformance cannot satisfy a generic constraint. That bites in
  two places that look nothing like concurrency: `XCTAssertEqual` on an app-side
  type from a nonisolated test method, and `navigationDestination(for:)` /
  `NavigationLink(value:)`, which need a plain `Hashable`. So mark `nonisolated`
  any app-side type that is a navigation value, is compared in a test, or is
  otherwise pure — `RatingContext`, `FormDisplay`, `BrowseRegions`,
  `CoursesViewModel.CourseListing` and `SettingsViewModel.TestResult` all carry it
  for exactly this reason. Kit types are unaffected: the kit sets no default.
- **A `@MainActor` XCTest method must be `async`.** A *synchronous* one does not
  run: XCTest invokes test methods from its own worker thread, and a synchronous
  main-actor-isolated method has no suspension point at which to hop, so it never
  executes its body. It does not error at compile time and it does not report an
  assertion failure — it reports `failed` in `0.000 seconds` with no message, and
  it takes the **rest of its suite** down with it, which is the confusing part: the
  remaining tests simply never appear in the results at all.
  This landed on `main` once. Of 55 tests, 41 passed, 6 "failed" with no message
  and 8 were never reported, and the split was exactly: every nonisolated test
  passed, every `@MainActor async` test passed, every `@MainActor` synchronous test
  failed. The tell is the arithmetic — reported count below the real count — so
  when a suite goes quiet, compare the two before hunting for a logic bug. Write
  `@MainActor func test_x() async`, with `async throws` when it throws, even when
  the body awaits nothing.
- **`Race.hasStarted` reads the real `Date()`**, so anything that takes an
  injected clock must not use it. `TipsViewModel` did, and the result was a view
  model that accepted a `now` closure and then ignored it for the one decision
  that mattered — what to rate and what to record. Every fixture off time sits in
  1970, so against the real clock the whole card read as already run and Tips
  produced nothing: eight tests failed at once with no obvious cause. Compare
  `offDateTime` against the injected instant instead, and keep `hasStarted` for
  display, where the real clock is the right one.
- **`race.offTime` is a *UK* string and must never be displayed raw.** The
  Racing API prints the off in Europe/London — "13:30" — and for the app's first
  weeks every view echoed that string directly. On a device in the UK it is
  right and free; anywhere else it is silently two or three hours out with
  nothing on screen saying so. It was reported from Greece as a Record-tab bug:
  the card showed "13:30" against a phone clock reading 15:14, so three races
  that had not yet run read as finished and unsettled, and the accuracy tracker
  looked broken when it was correct. `RaceTime.display(_:)` formats
  `race.offDateTime` — a real instant — and is the only thing that should appear
  where an off time goes. `RaceTime.timeZoneNote()` returns the one-line notice,
  and returns `nil` where none is needed: it compares the **current UTC offset**
  rather than the zone identifier, so Europe/Dublin is not nagged for a zone that
  keeps London's clock all year.
- **`Date.FormatStyle.timeZone(_:)` is not the counterpart of `.locale(_:)`,
  and the mistake compiles nowhere but reads perfectly.** `.locale(locale)`
  returns a style using that locale, so `.timeZone(timeZone)` looks like it does
  the same for the zone. It does not: it is one of the *field modifiers*
  (`.year()`, `.month()`, `.hour()`, `.timeZone()`) that append a symbol to a
  custom format, so it takes a `Date.FormatStyle.Symbol.TimeZone` and rejects a
  `TimeZone` with "cannot convert value of type 'TimeZone'". Set `locale` and
  `timeZone` as **properties** on a `var style`, which cannot be read as anything
  else. This took `main` red in Xcode Cloud build 18, and it went in as an
  unverified tidy-up of a `DateFormatter` that already worked — the actual fix
  it rode in with was fine.
- **`RaceResult.didRun(horseID:)` returns `nil` below three finishers**, and that
  is deliberate: a truncated payload would otherwise settle every runner as a
  non-runner and wipe a day's tips in one pass. The consequence for tests is that
  a two-runner result fixture leaves its tip `.unresolved` rather than won or
  lost, which reads as a bug in `RacesStore` and is actually the guard doing its
  job. `RaceResult.settleable(winner:)` and `settleableLoss(loser:)` in
  `Fakes.swift` build a field that clears the floor — use those unless the test
  is specifically about a short field.
- **`await` does not go inside an `XCTAssert`.** `XCTAssertEqual(await store.tips.count, 1)`
  and `try XCTUnwrap(await store.tip(forRace: id))` both fail to compile: the
  assertions take non-async autoclosures, and an `await` inside one is an error.
  Hoist the value into a local first. Unavoidable once anything is behind an
  actor, and it reads better anyway.
- **Optional-chaining an `async` call gives you a double optional.**
  `await environment?.refreshResults()` is `ResultsIngestion??` and will not
  assign to a `ResultsIngestion?`. Unwrap the optional first with `if let`.
- **A nested type or `static` inside an `actor` can still pick up the app
  target's MainActor default**, and every one of that actor's own methods runs
  off the main actor — so reading it from inside the actor fails to compile.
  `StoreDocument`, `ResultsIngestion` and `CachedRacecards` live at file scope as
  `nonisolated` declarations for exactly this reason, not nested in `RacesStore`
  where they would read more naturally.
- **A view model captures its dependencies when SwiftUI builds it, and `@State`
  keeps it alive across a credential change.** So handing a screen a *new*
  loader on `refresh()` does nothing: a screen built before the token was
  entered would hold "not configured" until the app was relaunched, which is the
  exact opposite of what `AppEnvironment.refresh()` exists to do. `ServerLink` is
  therefore one long-lived object whose server is replaced by `use(server:)`,
  and every view model holds the link rather than a server. (The old
  `MarketLoader` learned this first.)
- **"Matched a market" and "has prices" are two different claims, and the Tips
  coverage line makes the second one.** Betfair will return a book whose every
  runner has no back, lay, last-traded or forecast price. The rater is already
  safe from it — `Overround.impliedProbability` returns `nil` for such a runner,
  coverage comes out at 0, and the assessment stays form-only — but counting
  that race as priced would overstate the footer, which exists precisely to
  show when the model is *not* anchored. So the server's `priced` drops those
  books, and Tips counts races whose assessment has a market source.
- **`marketSource` is `MarketSnapshot.Source?`, so unwrap it before switching.**
  `switch assessment.marketSource { case .none: … }` reads as three cases and is
  really `Optional.none` competing with pattern promotion; `guard let source`
  first and the three branches stay three branches.
- **A factor shipped at zero weight needs its reason in the kit, not the view.**
  `FactorID.summary` and `FactorID.rationale` sit beside `label` so the Model
  screen and the weights it describes cannot drift, and so the Linux job covers
  the pairing — `FactorDescriptionTests` fails if a new factor arrives without
  copy, if `RatingWeights.v1` omits one, or if the set of deliberate zeros
  changes. The failure mode it guards is silent: a weight on screen with nothing
  explaining it looks like a finished row.
- **A matched market is worth recording even when nothing was priced.**
  In `service.priced` the references are deliberately a wider set than the snapshots:
  an early book with no money in it yields no snapshot, so the tip is form-only —
  but that race still settles with a Betfair SP hours later, and that is the ROI
  figure. Gating the reference on live prices would lose ROI for exactly the races
  that were hardest to price at the time.
- **The results pass makes two independent calls, and the second must not be able
  to cost the first.** `service.CollectResults` fetches the Racing API results and
  then Betfair's settled starting prices; `startingPrices` swallows the Betfair
  failure and falls back to the prices already stored. A failure there costs the
  ROI figure for those tips and nothing else — `tracking.Settle` settles them on
  the result alone. Losing
  the strike rate as well would be the real bug, and the free results endpoint is
  today-only, so there is no second attempt at it.
- **Dates cross to the app as whole seconds, or not at all.** Go's `time.Time`
  marshals RFC3339Nano, and Swift's `.iso8601` decoding strategy rejects a
  fractional second — one sub-second timestamp anywhere in a response makes the
  app discard the whole card. Every time in a response is a `domain.Instant`,
  which truncates. A new response field of type `time.Time` is the bug.
- **The trainer has a hard floor of 100 training races, whatever the
  configuration says.** It is in the Swift original too:
  `eligible.count - validationCount >= 100`. RacesKit's own trainer tests run at
  40 races and assert a fit, which that guard cannot reach — so the Go tests use
  150. If those Swift tests are red, that is why, and it predates the server.
- **Qualify the column inside `json_each`.** `json_each(json, '$.runnerIDs')` in
  an `UPDATE training_samples` silently matched nothing — the bare `json` is
  ambiguous with the function of the same name. `training_samples.json` works,
  and `TestTrainingWinner` exists because the failure was a quiet zero.
- **Don't hand `Optional.map` a main-actor closure.** `configuration.racingAPI.map(makeRacingProvider)`
  is the natural way to write `AppEnvironment.refresh()` and it fails: `map` wants
  a nonisolated closure, so passing an isolated one loses the global actor. An
  explicit `if let` has no conversion to get wrong.

## CI

Three workflows, split by cost rather than by tidiness.

| Workflow | Job | Runs when |
|---|---|---|
| `server.yml` | `Server (Go)`, then `Image (GHCR)` on `main` | `server/**` or the `server-*.json` contract fixtures change |
| `kit.yml` | `RacesKit (Linux)` | `ios/RacesKit/**` changes |
| `app.yml` | `Races (Xcode)` | `ios/Races/**`, `ios/RacesKit/Sources/**` or `Package.swift` changes |

`server.yml` pushes `ghcr.io/bensuskins/races-server:latest` (and a `sha-` tag
to roll back to) from `main`; the homelab's `update.yml` pulls it on its next
run, as it does the other self-built images.

**This repository is private, so every runner minute is billed — and macOS bills
at 10x.** On 2026-09-22 roughly 112 minutes of Xcode wall time billed at about
1,125 minutes, over half the 2,000-minute monthly allowance in a single day, and
Actions stopped scheduling jobs entirely: both checks began failing in two
seconds with no steps and no logs, which looks nothing like a build failure and
is easy to misread as one.

Two rules follow, and neither is cosmetic:

- **Every job needs `timeout-minutes`.** Without one a stuck job runs to
  GitHub's six-hour default, which on macOS is 3,600 billed minutes — 1.8x the
  monthly allowance from a single hang. Hangs are not hypothetical here: eleven
  synchronous `@MainActor` tests deadlocked on 2026-09-21 and the test phase ran
  12.8 minutes.
- **The Xcode job's paths include `ios/RacesKit/Sources/**`, and that is not an
  oversight.** The app compiles against the kit, so a public API change there can
  break the app target with no app file touched. Narrowing to `ios/Races/**`
  would save more and would lose real coverage. What *is* excluded is only what
  provably cannot affect the app build: the kit's own tests and fixtures.

Each workflow lists itself in its own `paths`. Without that a CI change cannot
be tested by the CI it changes, which is how every workflow edit in Family Hub
went in unverified. The concurrency groups are namespaced per workflow
(`kit-`/`app-`) or the two would cancel each other on the same ref.

## Accuracy

`docs/accuracy.md` records what the tracker measures and what it refuses to. Three
things in it exist specifically to stop the app flattering itself, and none should
be removed without a good reason: the **favourite baseline**, the
**agree/disagree split**, and **separate denominators** for strike rate and ROI.

The **sealing rule** is what makes any of it mean anything: a tip is a draft until
five minutes before the off, immutable after, and a race first opened after it has
run is never recorded at all.

All of it is now on screen in the Record tab, laid out so the favourite baseline
sits directly beneath the strike rate — the two are meaningless apart. ROI stays
hidden below 50 settled tips and says why, and coverage is shown whether or not it
flatters, because the free results endpoint is today-only and a race day the
server never saw is a result gone for good. Those tips expire and are counted
rather than dropped. The server enforces the rule now (`tracking.Decide`), so the
record no longer depends on anyone opening the app inside the window; tips
uploaded from a phone keep their `device:` source and are labelled on screen.

## Testing

- Go's `testing` on the server, XCTest in the kit and app, table-driven where it fits.
- The server is tested against fakes of both providers with an injected clock:
  `service_test.go` runs a whole race day — draft, seal, results, settlement,
  back-test — in milliseconds, and `api_test.go` drives the HTTP surface.
- Prefer fakes over mocks; fakes live in the test target alongside what they fake.
- Provider payloads are committed as fixtures under
  `ios/RacesKit/Tests/RacesKitTests/Fixtures/` and loaded via `Fixture.load(_:)`.
  **Strip credentials before committing a fixture.**
- The whole kit is testable with no network and no subscription. If a change can
  only be tested with live credentials, the seam is in the wrong place.

```bash
(cd server && go test ./...)                    # the server, in seconds
(cd server && go test ./internal/api ./internal/parity -update)  # regenerate the contract fixtures
swift test --package-path ios/RacesKit          # the kit, including ServerContractTests and ServerParityTests

# The app half. Needs macOS. CI runs this, resolving the simulator the same way.
xcodebuild test -project ios/Races/Races.xcodeproj -scheme Races \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available -j \
    | jq -r '[.devices[][] | select(.name | startswith("iPhone"))] | .[0].udid')" \
  CODE_SIGNING_ALLOWED=NO
```

App-side fakes live in `ios/Races/RacesTests/Fakes.swift`: `FakeRacesServer`
(scripted `Result`s per endpoint, defaulting to a loud "not scripted" failure,
plus call counts and the jobs and uploads it received) and
`InMemoryCredentialsStore` (which can also be told to throw, for the
broken-Keychain path), with `fixture` builders for `Race`, `Runner`, `Course`,
`RaceResult`, `ServerRacecard`, `ServerRecord` and `ServerStatus`, and
`temporaryHistory()` for `LegacyHistory`. Prefer extending those over writing a
second fake.

The app's cache is tested against `InMemoryDocumentStore` from the kit, which
round-trips through JSON exactly as `JSONFileStore` does. Constructing a
**second** `RacesStore` over the same document store is how a relaunch is
tested. On the server, a relaunch is a second `store.Open` over the same file.

An unsigned build has no keychain-access entitlement, so the real Keychain returns
`errSecMissingEntitlement` (`-34018`) in CI and in previews. That is why
`KeychainCredentialsStore` takes a `KeychainOperating` seam: the query building and
status mapping — the parts that actually break — are tested with a fake, and the
four `SecItem*` calls behind it are thin enough to read.

## Not betting advice

This is a personal tool for information only. Keep the disclaimer in Settings, and
keep the accuracy tracker honest — particularly the favourite benchmark, which is
what stops the model flattering itself.
