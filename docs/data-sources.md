# Data Sources Evaluated

**This file is not `docs/providers.md`.** That one lists the endpoints the app
actually calls and must stay in step with
`ios/RacesKit/Sources/RacesKit/Providers/`. This one lists sources we *looked at*
and what we decided about each. **Nothing in this file is wired up.** A source
moves from here to `providers.md` only when a call site exists.

Evaluated 2026-09-22.

---

## Why this file exists

Four of the twelve factors in `RatingWeights.v1` ship at zero weight. The obvious
guess is that they are waiting for a data provider we do not have. They are not.
Each is waiting for one specific, nameable thing:

| Factor | Weight | What it is actually waiting for | A free route? |
|---|---|---|---|
| `draw` | 0.00 | A course × distance × going × field-size bias **table**. `runner.draw` is already on every card | Racing Alpha's `get_draw_bias`, or forward from our own archive |
| `headgear` | 0.00 | `headgear_run`, to tell *first-time* headgear from headgear | **None.** Racing API Basic is the only source |
| `jockeyStrikeRate` | 0.00 | 30 runs per subject in `ResultsArchive`, which starts empty | Forward from our own archive. A prior can be seeded |
| `trainerStrikeRate` | 0.00 | Same | Same |

So the honest summary is that **three of the four are waiting for time or for a
tier we already have credentials for, and only `draw` has anything to gain from a
new source.** That is worth knowing before anyone spends an afternoon on an
integration.

---

## The rules a source has to pass

### Reference data only

Facts about the past may enter the model: draw bias, strike rates, historical
starting prices. Another operator's score, fair price, value flag or tip may not.

This is not squeamishness about borrowing. `docs/accuracy.md` exists to stop the
app flattering itself, and the favourite baseline — the number that decides
whether any of this is worth keeping — answers *is this algorithm any good?* only
while the algorithm is ours. Blend someone else's model in and the Record tab
still produces a figure, but nobody can say what it is a figure about. The
agree/disagree split has the same problem: it measures what the model contributed
over the market, which stops being meaningful once a third party's opinion is
inside the model.

The same reasoning rules out the reverse mistake of quietly re-deriving a number
we already compute. De-overrounding, for instance, is `Overround.impliedProbability`
and belongs in the kit.

### Free only, for now

Decided 2026-09-22. This is a budget decision rather than a technical one, which
means it is revisitable — so the paid options below are recorded with what each
would unlock rather than dismissed. The one to revisit first is the Racing API
tier, not a new vendor.

### Every runtime provider is a new matching surface

This is the architectural rule and the easy one to miss.

`docs/matching.md` explains why the join between our two existing feeds is built
to refuse: a race with no market falls back to form and says so, while a race with
the **wrong** market anchors every runner to another race's prices and looks
entirely normal. A third feed does not divide that risk, it adds to it.

Concretely, `RaceMatcher.match(races:markets:tolerances:)`
(`ios/RacesKit/Sources/RacesKit/Matching/RaceMatcher.swift:134`) takes one flat
`[ExchangeMarket]` and maintains a single `claimedMarketIDs` set
(`RaceMatcher.swift:146`). Feed it two
providers' catalogues concatenated and they **compete** for each race rather than
corroborating each other — whichever claims a race keeps it. There is no `source`
field on `ExchangeMarket`, no per-provider precedence, and `MarketReference.selectionIDsByHorseID`
is a `[String: Int64]` with no provider tag, which `docs/accuracy.md`
depends on resolving unambiguously hours later at settlement.

The favourable half is real too: `ExchangeMarket`, `MarketSnapshotJoin` and
`RaceMatcher` are already provider-agnostic and Foundation-only.
`ios/RacesKit/Sources/RacesKit/Matching/ExchangeMarket.swift:3-8` says so
outright — a Betfair catalogue entry maps into it, "so could anything else."

The conclusion to draw is a preference, not a prohibition:

> **Prefer a source that can be fetched once and committed as a static table over
> one that has to be called at runtime.**

A committed table adds no matching surface, no credentials, no rate limit and no
new runtime failure mode, and it keeps the rater pure — which is the property that
lets the back-test run on Linux in seconds.

---

## Verdicts

| Source | Verdict |
|---|---|
| Betfair free historical BSP | **Adopt, offline.** It builds the back-test's control arm |
| Racing Alpha — `get_draw_bias`, `get_combo_stats` | **Adopt as a committed table**, licence permitting |
| Racing Alpha — `get_race_signals`, `get_tips_ledger` | **Refuse.** Another model's output |
| The Racing API Basic / Standard / Pro | **Deferred, not rejected.** Out on budget, not merit |
| OurHub Racing | **No.** Paid, and keyed by nothing we can join on |
| The Odds API | **No.** No horse racing, and a bookmaker book is a worse anchor than the exchange |
| SportsEdgePro | **No API.** Recorded for what it shows is derivable |

---

## Betfair free historical BSP — adopt, offline

**What it is.** Betfair publishes settled starting prices as plain CSV, one file
per day per country and market type, at
`promo.betfair.com/betfairsp/prices/dwbfpricesukwin<DDMMYYYY>.csv`, with a fuller
archive behind a Betfair login at `historicdata.betfair.com`. No app key, no
session token, no rate limit.

**Columns.** `EVENT_ID`, `MENU_HINT`, `EVENT_NAME`, `EVENT_DT`, `SELECTION_ID`,
`SELECTION_NAME`, `WIN_LOSE`, `BSP`, `PPWAP`, `MORNINGWAP`, `PPMAX`, `PPMIN`,
`IPMAX`, `IPMIN`.

**Why it fits.** `SELECTION_ID` is the same id space as the one `MarketReference`
freezes onto every tip, which is what makes this genuinely ours to use rather than
a third feed to be matched. It is an offline batch job — a script and a committed
corpus — so it touches no runtime code path, needs no credential slot, and cannot
mis-price a live card.

**What it builds: the control arm.** `docs/roadmap.md` item 2 asserts
`logLoss(model) ≤ logLoss(market) + 0.005`. Half of that inequality is the market,
and this is years of it: real prices, real outcomes, enough to give the favourite
baseline, market log loss and ROI at BSP a sample that means something.

**What it does not build, and this is the important part.** There is no stall
draw, no official rating and no form in these files. A cloth number sometimes
prefixes `SELECTION_NAME`, and `CLAUDE.md` is explicit that a cloth number is not
a draw. So **this cannot produce a draw-bias table, and it cannot back-test the
model arm** — that needs historical racecards, which no free tier sells. The model
arm can only be built forward, from the app's own archive of cards it has seen.

**Free-tier limits.** The free data omits traded volume and the full price ladder,
keeping only a last-traded price per minute. Irrelevant here: we want BSP and the
outcome.

---

## Racing Alpha — split verdict

**What it is.** A UK and Irish racing model that publishes its own signals through
a public API and an MCP server at `https://racingalpha.co.uk/api/mcp` (streamable
HTTP, stateless). Keyless access is 50 requests a day per IP; a free key passed as
`Authorization: Bearer ra_live_…` raises it to 1,000. The free tier requires
visible attribution — "Signals by Racing Alpha", linked.

Five tools, and they fall cleanly on either side of the reference-data rule.

**May use — reference data:**

- `get_draw_bias` — draw bias by course. This is the **only free route to a draw
  table now** rather than after a year of accumulating our own. It is a fact about
  past races, not a prediction about today's.
- `get_combo_stats` — jockey/trainer combination statistics. Not a replacement for
  `StrikeRateFactor`, but a candidate **prior**. `StrikeRateRecord.smoothed(towards:strength:)`
  shrinks a thin record toward `ResultsArchive.baselineStrikeRate` with 20 notional
  prior runs, and that baseline is a flat 0.125 until the archive holds 100 runs of
  its own. Shrinking toward a measured figure would beat shrinking toward a guess
  in exactly the early period where the factor is switched off anyway.

**May not use — another model's output:**

- `get_race_signals` — 0–100 model scores, de-overrounded consensus prices, value
  flags.
- `get_tips_ledger` — their settled selections.

These are well-made and beside the point. Consuming them would make our
recommendation partly theirs while the Model tab still explains it as twelve
factors and two parameters, and it would quietly empty the Record tab of meaning.
The de-overrounding in particular we already do ourselves.

**Shape, if adopted.** Fetch once, commit the table, ship it in the kit. Do not
put it on a runtime path. Three reasons: the matching-surface rule above; the
rater's purity, which the back-test depends on; and the attribution requirement,
which is a term on a free tier that can change under us.

**Before building anything against it, check the licence.** A table we fetch and
redistribute inside a shipped app is a different question from a call we make at
runtime, and the free tier's attribution requirement suggests they have a view on
it. Worth asking them directly.

---

## The Racing API paid tiers — deferred, not rejected

The incumbent, and the honest comparison for everything above: we already hold
credentials, `ProviderCapability` already models the tiers, and `formHistory`
already throws `tierUnavailable` in the one place that matters. A tier upgrade
adds **no matching surface at all**. `docs/providers.md` has the endpoint table;
this is what it means for the zero-weight factors.

| Tier | What it would switch on |
|---|---|
| Basic | `headgear_run` — the only thing anywhere that switches `HeadgearFactor` on. Also `rpr`, `ts`, `trainer_14_days`, `stalls`, `going_detailed` |
| Standard | `/v1/jockeys/{id}/analysis/*` and `/v1/trainers/{id}/analysis/*`, returning `win_%`, `1_pl` and **`a/e`** |
| Standard | `/v1/results` with `sp_dec` — starting prices **without Betfair** |
| Pro | `/v1/horses/{horse_id}/results` — full career history, the input `HorseRun` was written for |

Two of those deserve emphasis, because they are better than they look:

**`a/e` is better than the strike rate we are waiting to compute.** Actual wins
over expected wins, where expected is derived from SP. A raw strike rate rewards a
trainer for running favourites; a/e does not. `StrikeRateFactor` is waiting to
accumulate the weaker of the two statistics.

**`sp_dec` would de-risk the roadmap's top blocker.** `docs/accuracy.md` records
that ROI comes from Betfair SP and nothing else, which is why ROI is structurally
a subset of strike rate and why the subset is not random. A second SP source would
break that dependency — and it would blunt the worst outcome of the Betfair login
spike, where `CERT_AUTH_REQUIRED` means interactive login can never work for the
account.

Deferred 2026-09-22 on the free-only decision. Nothing about the code needs to
change for this to become available later; that is the point of
`ProviderCapability`.

---

## OurHub Racing — no

**What it is.** `racing.ourhub.site`. Four date-keyed endpoints —
`/api/course-info/{race_date}`, `/api/runner-info/{race_date}`,
`/api/performance-stats/{race_date}`, `/api/predictions/{race_date}` — behind an
`X-API-Key` header. £5/month for the first two at 1,000 requests a day, £10 adding
performance stats at 10,000, £20 adding predictions.

**The appeal.** `performance-stats` returns jockey and trainer runs, wins and
win-rates for a whole card in one call, which is exactly the cold start that
`jockeyStrikeRate` and `trainerStrikeRate` are sitting out.

**Why not.** Three reasons, in increasing order of weight:

- It is paid, and the free-only rule applies.
- It overlaps almost entirely with Racing API Standard, which we could buy
  instead with no new matching surface and get `a/e` rather than a raw win rate.
- **Its payloads carry no ids.** The published sample is keyed by course name with
  a `"race_time": "14:00"` string and nothing else — no race id, no horse id. That
  is a third matching surface with weaker evidence than Betfair's, joined on
  exactly the two signals `docs/matching.md` calls the weakest. And a bare
  `"14:00"` is the same UK-local trap that `RaceTime.display(_:)` exists to close.

**What would change it.** If the free-only rule lifts, price the Racing API tier
first. This sits below it.

---

## The Odds API — no

`the-odds-api.com`. A bookmaker odds aggregator for team sports. Two independent
reasons, and the second holds even if the first turns out to be wrong.

- **Coverage.** No horse racing that we could find. Its market vocabulary is
  team-sport shaped — h2h, spreads, totals — with no runner-level concept.
- **It would be a downgrade even if it had racing.** A bookmaker book runs around
  115–125% overround; the Betfair exchange runs around 102%. The rater anchors on
  an implied probability, and a bookmaker's is a worse estimate of the same
  quantity than the one we already have. Adding it would mean matching a third
  feed in order to be less accurate.

If the intent behind "an odds API" is *more than one price source*, the in-house
version is Racing API Standard, which carries 20+ bookmakers for UK and Irish
racing — see the tier table above.

---

## SportsEdgePro — no public API

`horses.sportsedgepro.co.uk`. A web analytics tool over roughly 4 million BSP
runner records for UK, Irish, Australian and US racing since 2020, with AND/OR
filters across class, distance, draw, BSP rank, last time out, win percentage and
days since last run, and year-by-year P&L.

There is no public API, so there is nothing to integrate. It is recorded here for
what it demonstrates rather than what it offers: **that is a product built on the
free Betfair BSP files joined to racecard data.** The filter list is a reasonable
specification for what our own corpus could support once the archive has run for a
while — and a reminder that the join to card data, which they have done and we
have not, is the expensive half.

---

## None of this was verified live

**Read the dates and check before building.** The egress proxy in the Claude
session that produced this file blocked `racingalpha.co.uk`, `the-odds-api.com`,
`api.the-odds-api.com`, `horses.sportsedgepro.co.uk` and `promo.betfair.com`.
Every claim above about those four sources comes from published documentation as
of 2026-09-22, not from a successful request.

The one exception is the Racing API tier table, which was taken from its published
OpenAPI spec and did fetch successfully.

Two checks, in the style `docs/providers.md` uses. Either failing means the
matching section above is wrong and should be corrected before anything is built
on it:

```bash
# Betfair free BSP for a given day. No auth. Expect a CSV header row.
curl -s "https://promo.betfair.com/betfairsp/prices/dwbfpricesukwin22092026.csv" | head -5

# Racing Alpha, keyless. Expect five tools, including get_draw_bias.
curl -s -X POST "https://racingalpha.co.uk/api/mcp" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

---

## Adding to this file

A source enters with a verdict and a date, including the ones we say no to —
recording *why not* is most of the value here, because otherwise the same
evaluation gets redone in six months from the same starting ignorance.

A source leaves this file for `docs/providers.md` only when a call site exists in
`ios/RacesKit/Sources/RacesKit/Providers/`, and `CLAUDE.md`'s doc-drift rule takes
over from there.
