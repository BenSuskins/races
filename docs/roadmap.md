# Roadmap

Everything in the original plan (M0–M6) is built and merged. What follows is the
work that is actually left, with the dependencies between the items made explicit
— because two of them look ready and are not.

Each item says **who owns it**, since several need a device, real credentials or a
billing decision rather than a commit.

Updated 2026-09-24, when the Go server replaced the on-device pipeline.

---

## The server — deploy and follow-ups

The Go server (`server/`) now owns the providers, rating, sealing, settlement,
retraining and back-tests; the app reads from it. What is left to make that real:

### Deploy it

**Owner: Ben. Needs the vault and the homelab.**

1. Add to `~/.ansible/vault.yml`: `RACES_API_TOKEN` (any long random string —
   `openssl rand -hex 32`), `RACING_API_USERNAME`, `RACING_API_PASSWORD`, and
   optionally `BETFAIR_APP_KEY`, `BETFAIR_USERNAME`, `BETFAIR_PASSWORD`.
2. Merge the homelab PR and let `update.yml` deploy `races-server` to the
   `docker` host. The image comes from this repo's `server.yml`, which needs
   Actions minutes to run on `main` (see the live blocker below).
3. Check `https://races-api.suskins.co.uk/healthz` from home and over Tailscale.
4. On each phone: Settings → server token → **Test connection**, then **Upload
   history**. The Record tab should show the same figures it did before, now
   labelled as uploaded.

### Back up `races.db`

**Owner: Claude, once asked. The top open risk.**

The database is the only copy of every result the free tier cannot re-fetch.
There is no backup, by choice at the time. `store.Backup` already does an online
`VACUUM INTO`; the homelab's `wedding-db-backup` task (nightly, 14 days,
stale-backup alert) is the pattern to copy, ideally with a copy off the host.

### Delete the Swift rater and provider clients

**Owner: Claude. Depends on `ServerParityTests` having passed once.**

The app no longer calls `Providers/`, `Matching/` (bar `CourseNameNormaliser`),
the rater or `OnDeviceWeightTrainer`. They stay only so `ServerParityTests` can
prove the Go port produces the same numbers. Once that test has run green —
on the Linux job or locally — they can go, with their tests.

### RacesKit's trainer tests cannot pass

**Owner: Claude. Found during the port.**

`OnDeviceWeightTrainer` refuses to fit below 100 training races whatever the
configuration says, and its tests use 40. The Go port keeps the guard and tests
at 150. The Swift tests need the same change (or the guard a configuration
knob), or they will be red the next time the kit job runs.

### Forecast prices need `SP_PROJECTED`

**Owner: Claude, after the Betfair spike.**

The price join reads `sp.nearPrice` as the forecast anchor for tomorrow's thin
markets, but `listMarketBook` is only asked for `EX_BEST_OFFERS`, and Betfair
returns `nearPrice` only for `SP_PROJECTED`. The port kept the request identical
to the Swift client on purpose; adding the projection is a one-line change to
`betfair.Client.Prices` and `docs/providers.md` together.

---

## Blocked on you

### Betfair login spike

**Owner: Ben. Two minutes. The biggest remaining unknown in the design.**

Settings → Betfair → enter app key, username and password → **Test Betfair**.

The screen reports which of three things happened, and carries Betfair's own code
either way:

| Result | Meaning | What follows |
|---|---|---|
| Connected — *N* win markets today | Interactive login works | Nothing. Carry on |
| Didn't recognise that username and password | Bad credentials | Re-enter them |
| Sign in at betfair.com first (`SECURITY_QUESTION_REQUIRED`, `PENDING_AUTH`, …) | 2FA or a challenge | Clear it in a browser, test again |
| Certificate login required (`CERT_AUTH_REQUIRED`, `SECURITY_RESTRICTED_LOCATION`) | **Interactive login can never work for this account** | Reshapes the Betfair layer |

The last row is why this is urgent rather than tidy. Three merged PRs now sit on
top of interactive login — the client (#15), the wiring (#17) and ROI (#19) — and
certificate login is not a small change: it needs a `URLSessionDelegate` supplying
a client identity from the Keychain, and Settings changes shape to collect a
certificate rather than a password.

`BetfairSession` **latches** that failure rather than retrying, so a wrong answer
here is safe to discover: it will not hammer the exchange or risk locking the
account.

---

## Ready to build

### 1. A capture script, and real fixtures

**Owner: Claude writes it, Ben runs it.**

A script that pulls a real card and its results with your Racing API credentials,
plus the corresponding Betfair catalogue, strips credentials, and writes committed
fixtures under `ios/RacesKit/Tests/RacesKitTests/Fixtures/`.

This is the **prerequisite nothing else admits to needing**. `docs/matching.md`
already says it plainly under Known limitations:

> **No fixture pairs yet.** The tests are hand-built. Real paired captures — a
> Racing API card and the corresponding Betfair catalogue for the same afternoon —
> would be worth more than any of them.

So the matcher — the component whose failure mode is the worst in the app, pricing
one race off another's market — is currently tested only against races that were
invented to pass it.

Cannot be run from a Claude session: it needs live credentials, and the providers
are outside this environment's network policy.

### 2. Back-test harness and CI job

**Owner: Claude. Partly built: `POST /v1/backtests` on the server re-rates every
sealed race from its stored card and seal-time prices, and scores every frozen
snapshot, against the market. What is left is the CI assertion over real
history, which depends on item 1 for fixtures and item 4 for the control arm.**

Runs the rater over past races with known results and reports strike rate, ROI,
the favourite baseline and log loss for the model and for the market. Pure and
Foundation-only, so it runs on Linux in seconds.

The assertion that matters, from `docs/algorithm.md`:

```
logLoss(model) ≤ logLoss(market) + 0.005
```

This is the concrete form of "β = 0 reproduces the market", and it makes the
single question worth asking about this app — *does any of this beat simply
backing the favourite?* — a check rather than an opinion.

**It can be built before item 1 and should not be trusted before it.** A harness
run against fixtures someone invented proves the harness works. It says nothing
about the model. Roughly 150 real races is enough for regression testing and
nowhere near enough for statistical inference; say so whenever quoting a number
from it.

The two sides of that inequality arrive separately, which is why item 4 exists.
Item 4 gives the **market** side real prices and real outcomes at a scale worth
quoting. Item 1 gives the **model** side its cards. A harness with only the first
can still say what backing the favourite returns, which is not nothing — it is the
number the whole app is measured against.

### 3. Real app icon

**Owner: Claude, or Ben if you have artwork.**

`scripts/make-app-icon.py` currently generates a placeholder.
`AppIcon.appiconset` needs a real 1024×1024 PNG **with no alpha channel** or App
Store Connect rejects the marketing icon.

Small, self-contained, and the only item here that Xcode Cloud verifies today.

### 4. A market corpus from Betfair's free BSP files

**Owner: Claude writes the script, Ben runs it.**

Betfair publishes settled starting prices as plain CSV, no app key and no session
token, at `promo.betfair.com/betfairsp/prices/`. A script that pulls a range of
days and writes a committed corpus would give item 2 the half of its assertion
that our own archive cannot supply for months yet:

```
logLoss(model) ≤ logLoss(market) + 0.005
```

`SELECTION_ID` in those files is the same id space `MarketReference` already
freezes onto every tip, so this is not a third feed to be matched — it is the one
we already use, settled. It is an offline batch job, so it touches no runtime
path, needs no credential slot and cannot mis-price a live card.

**What it cannot do, which is the part worth reading twice.** The files carry no
stall draw, no official rating and no form. So this builds the **control** arm —
the favourite baseline, market log loss, ROI at BSP — and not the model arm, which
needs historical racecards that no free tier sells. It also cannot produce the
draw-bias table `DrawFactor` is waiting on; `docs/data-sources.md` has the one
free route to that and its caveats.

Cannot be run from a Claude session: `promo.betfair.com` is outside this
environment's network policy, the same constraint as item 1.

---

## Blocked on the above

### Editable weights in the Model tab

**Owner: Claude. Blocked on item 2.**

The Model tab ships read-only on purpose. `weightsID` is stamped onto every stored
tip, so editing a weight either invalidates the accuracy history silently (same
id) or splits the ledger into two populations (new id).

Making it editable therefore needs three things, not one:

1. A new `weightsID` generated automatically on every change.
2. The Record tab grouping its figures by `weightsID`, so two populations are
   never blended.
3. The back-test, so a changed weight can be judged an improvement rather than
   merely a difference.

Without (3) the feature is a way to make the accuracy record worse while feeling
productive.

---

## Live blockers — not work items

### GitHub Actions cannot start jobs

Every run on 2026-09-22 from 06:15 onward failed in 1–12 seconds with
`runner_id: 0`, no steps and 404 logs, on both `ubuntu-latest` and `macos-15` and
across both workflow files. Over five hours of it, which rules out a transient
incident.

Cause: exhausted Actions minutes. The repository is private so every minute bills,
and macOS bills at 10×; roughly 112 minutes of Xcode wall time billed at about
1,125 of the 2,000-minute monthly allowance in a single day. `CLAUDE.md § CI` has
the detail and the two mitigations already landed in #16.

Unblocked by: the allowance resetting, a higher limit under **Settings → Billing →
Actions**, or making the repository public.

### The kit's tests have never run on the current code

Xcode Cloud is a separate service and is **not** blocked — it builds and deploys
`main`, which covers the app target and `RacesKit`'s sources.

But `Races.xcscheme` lists only `RacesTests` under `<Testables>`. `RacesKitTests`
is a Swift package test target and is not built by building the app, so the kit's
~520 tests are covered **only** by the blocked Linux job.

Two guarantees merged in #19 without ever being executed:

- a tip ledger written before the `marketReference` field existed still decodes
- a Betfair starting price can never land on the wrong horse

Both are the kind that fail silently. The first is the more serious: the accuracy
record cannot be regenerated, because the free results endpoint covers today only.

**Worth adding `RacesKitTests` to the scheme** so Xcode Cloud runs them too. Not
listed above as a work item because it changes what every Cloud build costs and
that is a decision, not a chore.

---

## Not a work item, but the thing the app most needs

Race days. The archive starts empty, so:

- jockey and trainer strike rates contribute nothing until it fills — the Model
  tab reports them as *waiting* rather than live, which is accurate
- ROI stays hidden below 50 settled tips, and says why
- the favourite baseline — the number that decides whether any of this is worth
  keeping — needs a sample before it means anything
- the draw-bias table `DrawFactor` needs is a course × distance × going ×
  field-size interaction, and every card the app sees is a row of it

Every item above is speculative until there is evidence the model does something.
A week of real cards produces more information about what to build next than any
of them.

One thing to watch while it runs: **if the Record tab shows no history after
updating**, that is the ledger-decoding path failing, and it is worth reporting
immediately rather than clearing and starting over.
