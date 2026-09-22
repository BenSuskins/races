# Races — Developer Context

UK horse racing for iOS: browse **course → race → runner**, get an explainable
recommendation for each race, and track how well those recommendations actually do.

Native SwiftUI app plus a Foundation-only Swift package. **No backend** — the app
talks to two third-party providers directly and keeps its own history on device.

## What is left

`docs/roadmap.md` is the current backlog: what remains, who owns each item (some
need a device, real credentials or a billing decision rather than a commit), and
the dependencies between them — two items look ready to build and are not. It also
records the live blockers, which are not work items: the Actions quota, and the
fact that `RacesKitTests` is absent from `Races.xcscheme` so the kit's tests are
covered only by the Linux job.

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

### App targets

| Target | Directory | Notes |
|--------|-----------|-------|
| `Races` | `ios/Races/Races/` | The app. Folder-synced group, so new files need no project edit |
| `RacesTests` | `ios/Races/RacesTests/` | Unit tests hosted by the app, for what cannot live in the kit |

```
ios/Races/Races/
├── App/           # AppEnvironment, RacesStore, RacecardLoader, MarketLoader, BackgroundRefresh
├── Components/    # StateContentView, ErrorStateView, RaceRow
├── Today/         # Today's and tomorrow's meetings
├── Tips/          # The model's selection per race
├── Courses/       # Every course, searchable — pushed from Racing, not a tab
├── Model/         # The algorithm on screen: weights, factors, guardrails
├── Race/          # Race card, runner detail, the factor breakdown
├── Record/        # Strike rate, favourite baseline, coverage
├── Settings/      # Credential entry, connection test, disclaimer
└── Credentials/   # KeychainCredentialsStore
```

Three types carry the app's state, and each has one job:

- **`AppEnvironment`** — the only place that decides whether a provider exists.
  Every view model takes an optional dependency plus an `unavailable: APIError?`
  and reports that rather than inventing one, which keeps "not configured" a
  single decision instead of one per screen. It also owns `refreshResults()`,
  the **single** path for collecting results, shared by launch, the Record tab
  and the background task.
- **`RacesStore`** — an `actor` owning persistence, the tip ledger, the results
  archive, the racecard cache and the rater. An actor because persistence is
  async and the background task touches it off the main thread; one actor so a
  tip write and a results ingest cannot interleave. It never reaches the
  network — it is handed races and results and decides what to keep, which is
  what makes it testable against `InMemoryDocumentStore` with no provider.
- **`RacecardLoader`** — reads a day's card through the disk cache, shared by
  Today and Tips so the two cannot disagree about what is running and opening
  both costs one request, not two.
- **`MarketLoader`** — the fourth, and the only one that is a single long-lived
  instance. It fetches Betfair's catalogue, runs `RaceMatcher`, prices **only
  the markets that matched**, and returns `MarketLoad`: snapshots keyed by *our*
  race id, plus the matcher's refusals and any failure. It never throws, because
  no market is an ordinary state. Its provider is swapped in place by
  `AppEnvironment.refresh()` rather than the loader being replaced — see the
  gotcha below.

Tabs are **Racing, Tips, Model, Record, Settings** — and five is the ceiling.
iOS collapses a sixth into a "More" list, which would bury Settings, where
credentials are entered. So the course directory is **pushed from Racing** rather
than holding a tab: Racing's own search covers the meetings on today's card, and
the directory covers the courses with no fixture, which is the only thing the
card cannot tell you.

**The Model tab is read-only, and that is a constraint rather than an omission.**
`weightsID` is stamped onto every stored tip, so editing a weight without
changing the id silently invalidates the accuracy history — and changing the id
splits the record into two populations the Record tab would have to keep apart.
Tuning belongs behind the back-test, which can say whether a changed weight is
better or merely different. What the screen does show is everything: all twelve
factors including the four at zero, α and β, the clip, the coverage floor and the
form-scoring table.

**Prices are fetched before tips are recorded, never after.** Recording is what
seals a tip, so `TipsViewModel` loads the market first and hands the snapshots to
`assessAndRecord`. A tip sealed form-only and re-rated with prices afterwards
would be a record of something the user was never shown.

**Only `TipsViewModel` records tips, and it records the whole card.** Not the
races the user happened to open: a ledger of races that looked interesting is a
biased sample, and the favourite baseline would be measured against a different
population from the tips. `RaceView` assesses for display and never writes.

`Races.xcodeproj` is **checked in and was written by hand**, not generated by
Xcode — see the gotcha below. The macOS CI job is what validates it.

```
ios/RacesKit/Sources/RacesKit/
├── Core/          # ViewState, APIError, RetryPolicy, RateLimiter, HTTPClient
├── Models/        # Course, Race, Runner, RaceResult — provider-agnostic domain types
├── Providers/     # RacingAPI + Betfair clients behind two protocols
│   ├── RacingAPI/ # Client, DTOs, mapping
│   └── Betfair/   # Session (login/keep-alive), client, DTOs, faults, mapping
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

`MarketDataProviding` returns `ExchangeMarketPrices`, keyed by Betfair's own
**selection id** — deliberately not `MarketSnapshot`, which is keyed by *our*
horse id and can only exist after matching has joined the two providers. Handing
the rater exchange-keyed prices would mean it had to know two providers exist,
which is the thing the matching layer is for. `BetfairMapping.snapshot(from:horseIDsBySelectionID:)`
is the one place that crossing happens, and it **drops** unmatched selections
rather than guessing.

**`MarketReference` is the one exception, and it is deliberate.** Settlement is a
different job from rating: Betfair returns starting prices keyed by its own
selection ids, and by the time a race settles the catalogue that would let us
re-derive the mapping may be gone. So `RaceMarketMatch.reference()` freezes
`marketID` plus the whole field's `horseID → selectionID` map onto the `TipRecord`
at the moment the match was made and believed. It stores the **whole field**, not
just the selection, because the favourite baseline needs a price too — priced tip
against priceless benchmark is the most flattering possible asymmetry. Keyed our
id → theirs so the stored ledger is a readable JSON object rather than a flat
alternating array.

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

**Matching refuses rather than guesses** — `docs/matching.md` has the design.
The rule that shapes it: a race with no market falls back to form only and says
so, while a race with the *wrong* market silently anchors every runner to another
race's prices and looks entirely normal. So ties, thin overlaps and ambiguity are
all refused, and every refusal carries a reason.

**Credentials cross the module boundary as a protocol** — `CredentialsStoring` and
`ProviderConfiguration` live in the kit; `KeychainCredentialsStore` implements them
in the app. *Which* secrets count as a configured provider is kit logic, and
therefore tested on Linux; only the `SecItem*` calls are app-side. Half-configured
is not configured: a username with no password would 401 and the user would be
told their credentials are wrong rather than that a field is blank.

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
  loader on `refresh()` does nothing: Tips would still hold the one with no
  Betfair provider until the app was relaunched, which is the exact opposite of
  what `AppEnvironment.refresh()` exists to do. `MarketLoader` is therefore one
  long-lived object whose provider is replaced by `use(provider:)`, clearing its
  caches — prices fetched under another app key are not ours to show.
- **"Matched a market" and "has prices" are two different claims, and the Tips
  coverage line makes the second one.** Betfair will return a book whose every
  runner has no back, lay, last-traded or forecast price. The rater is already
  safe from it — `Overround.impliedProbability` returns `nil` for such a runner,
  coverage comes out at 0, and the assessment stays form-only — but counting
  that race as priced would overstate the footer, which exists precisely to
  show when the model is *not* anchored. So `MarketLoader` drops those books,
  and the two numbers cannot disagree.
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
  `MarketLoad.references` is deliberately a wider set than `MarketLoad.snapshots`:
  an early book with no money in it yields no snapshot, so the tip is form-only —
  but that race still settles with a Betfair SP hours later, and that is the ROI
  figure. Gating the reference on live prices would lose ROI for exactly the races
  that were hardest to price at the time.
- **The results pass makes two independent calls, and the second must not be able
  to cost the first.** `refreshResults()` fetches the Racing API results and then
  Betfair's settled starting prices; `betfairStartingPrices(now:)` swallows every
  failure and returns `[:]`. A failure there costs the ROI figure for those tips
  and nothing else — `ResultReconciler` settles them on the result alone. Losing
  the strike rate as well would be the real bug, and the free results endpoint is
  today-only, so there is no second attempt at it.
- **Don't hand `Optional.map` a main-actor closure.** `configuration.racingAPI.map(makeRacingProvider)`
  is the natural way to write `AppEnvironment.refresh()` and it fails: `map` wants
  a nonisolated closure, so passing an isolated one loses the global actor. An
  explicit `if let` has no conversion to get wrong.

## CI

Two workflows, split by cost rather than by tidiness.

| Workflow | Job | Runs when |
|---|---|---|
| `kit.yml` | `RacesKit (Linux)` | `ios/RacesKit/**` changes |
| `app.yml` | `Races (Xcode)` | `ios/Races/**`, `ios/RacesKit/Sources/**` or `Package.swift` changes |

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
flatters, because the free results endpoint is today-only and a race day the app
never saw is a result gone for good. Those tips expire and are counted rather
than dropped.

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

# The app half. Needs macOS. CI runs this, resolving the simulator the same way.
xcodebuild test -project ios/Races/Races.xcodeproj -scheme Races \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available -j \
    | jq -r '[.devices[][] | select(.name | startswith("iPhone"))] | .[0].udid')" \
  CODE_SIGNING_ALLOWED=NO
```

App-side fakes live in `ios/Races/RacesTests/Fakes.swift`:
`FakeRacingDataProvider` (scripted `Result`s for cards, courses and results, plus
call counts, so caching and degradation are assertable) and
`InMemoryCredentialsStore` (which can also be told to throw, for the
broken-Keychain path), with `fixture` builders for `Race`, `Runner`, `Course`,
`RaceResult` and `Finisher`. Prefer extending those over writing a second fake.

The store is tested against `InMemoryDocumentStore` from the kit, which
round-trips through JSON exactly as `JSONFileStore` does — so a type that fails
to encode fails in the tests too. Constructing a **second** `RacesStore` over the
same document store is how a relaunch is tested, and that is the only honest way
to prove persistence.

An unsigned build has no keychain-access entitlement, so the real Keychain returns
`errSecMissingEntitlement` (`-34018`) in CI and in previews. That is why
`KeychainCredentialsStore` takes a `KeychainOperating` seam: the query building and
status mapping — the parts that actually break — are tested with a fake, and the
four `SecItem*` calls behind it are thin enough to read.

## Not betting advice

This is a personal tool for information only. Keep the disclaimer in Settings, and
keep the accuracy tracker honest — particularly the favourite benchmark, which is
what stops the model flattering itself.
