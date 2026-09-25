# Improving the strike rate — a plan

Written 2026-09-25 against a Record tab reading 25 wins from 70 settled tips
(35.7%) with the favourite at 31.8%. This is the order of work for making the
model pick more winners, with what each step needs, what it costs and what it
cannot tell us. It is a plan, not a result: nothing below is proven until the
back-test says so.

`docs/algorithm.md` describes the model this plan changes; `docs/accuracy.md`
describes how it is scored; `docs/roadmap.md` holds the wider backlog this plan
slots into. Item numbers here are independent of the roadmap's.

---

## Two things to be clear about before touching anything

### The current record cannot yet tell good from lucky

A Wilson 95% interval on 25/70 runs from roughly 25% to 47%. The favourite's
31.8% sits inside it. Separating a real 35% from a 32% favourite at 95%
confidence needs several hundred settled tips per arm (`docs/accuracy.md` puts
it at about 160 per arm from 30%). So **live strike rate cannot be the
instrument for judging any change made this autumn.** The back-test is the only
thing fast enough, and it only replays races the server itself sealed, from
their stored card and seal-time prices. Uploaded phone history carries frozen
z-scores only, so it can re-weight factors but cannot re-rate a race with a
different de-vig method or form table.

At roughly 25–40 UK and Irish races a day, the server-sealed corpus reaches a
few hundred races in a fortnight and the trainer's 500-race floor inside a
month. Every item below that says "back-test" means "wait for that corpus,
then run it", and the earlier items are the ones whose cost is lowest while
waiting.

### Strike rate and return pull in opposite directions

The selection rule (`docs/selection.md`) picks the runner with the largest
value edge over 5%, not the most likely winner. That is why 25 of the 66
benchmarked tips disagreed with the favourite. It lowers strike rate on
purpose, in exchange for price. The highest-strike-rate policy available is
"back the favourite", which wins about a third of UK races and loses money.

So the first decision is the objective:

- **Strike rate** — tighten selection towards the favourite; expect ROI to fall.
- **Return** — keep value selection; expect strike rate near or below the
  favourite's and judge on ROI over the disagreed subset.

The plan below assumes strike rate is the target, because that is what was
asked, but it keeps the probability model and the selection policy separate so
the same work serves either. Item 0.3 makes the cost of the choice visible in
every back-test run rather than leaving it as an argument.

---

## Phase 0 — measure honestly (no algorithm change)

Everything later is judged by these. Build them first.

### 0.1 Compare like with like on the Record tab

**Owner: Claude. Small. Go + kit + fixtures.**

`beatsFavouriteOnStrikeRate` compares the model over every settled tip (25/70)
against the favourite over only the tips that had a market favourite frozen at
sealing (21/66). `docs/accuracy.md` names this exact asymmetry as the one the
three honesty figures exist to prevent. Today it happens to understate the
model, since the four form-only tips all lost; it flatters it the day a
form-only tip wins.

- Add a subset to `tracking.Report` for the model over the benchmarked races
  (the union of the agree and disagree subsets), and compare that against the
  favourite baseline.
- Show it in the benchmark section as the strike rate the favourite is being
  compared with, so the two rows share a denominator on screen.
- Reword the "Includes N tips uploaded" footnote, which counts every uploaded
  tip settled or not and so reads 73 under a heading saying 70.
- Regenerate `server-record.json` with `-update`; run the Swift contract tests.

### 0.2 Put the uncertainty on screen

**Owner: Claude. Small. Kit only, Linux-tested.**

A `strikeRateInterval` (Wilson, 95%) on `AccuracyReport`, shown beside the
strike rate and beside the favourite's. Until the two intervals separate, the
tab should say the record is consistent with the favourite, in words. This is
what stops a run of good days being read as a result.

### 0.3 Make the back-test answer the selection question

**Owner: Claude. Medium. Server only.**

`backtest.Run` reports one model arm: the value selection. Add a second,
`highestProbability`, over the same races, so every run shows what the
selection policy costs or earns in strike rate and ROI against picking the
model's most likely winner. Also report the agree/disagree split per arm, as
the Record tab does, since the disagreed subset is where the model's own
information is.

Add a `sweep` shape to `POST /v1/backtests`: a base weight set plus a list of
field overrides, returning one report per variant with a shared race set. The
runner already takes arbitrary `weights`, so this is a loop and a response
shape, not new replay logic. A `scripts/backtest-sweep.sh` that posts the
sweeps used below and prints a table keeps the runs reproducible and gives
`docs/algorithm.md`'s back-test log its rows.

### 0.4 A way to install a weight set

**Owner: Claude. Small. Server only.**

Today weights change only when nightly training promotes a candidate. Nothing
in the plan can be *applied* without a way to install a set deliberately. Add
`POST /v1/admin/weights` taking a full `Weights` body, minting a new id, storing
it with origin `manual` and making it active. The Model tab is unchanged and
stays read-only; this is a server admin call behind the same token, used from
the command line after a back-test, never from the app. `weightsID` on every
tip keeps the populations apart in `GET /v1/record?weightsID=`.

---

## Phase 1 — cheap, reversible, no new data

Each of these is a back-test run followed by 0.4. None needs a provider, a
device or money.

### 1.1 Power-method de-vigging

**Owner: Claude runs the sweep; Ben decides. Sweep only.**

Proportional de-vigging spreads the overround evenly across the field. The
favourite–longshot bias concentrates it on the outsiders, so proportional
over-prices longshots and the value selector then sees edge on exactly those
runners. The power method (`Σ pᵢ^k = 1`) is implemented and one field away:
`overroundMethod: "power"`.

Sweep: `{proportional, power}` × the current weights. Promote if log loss does
not worsen and strike rate rises, which is the expected direction.

- Pros: implemented, one field, corrects a known bias in the direction wanted.
- Cons: fewer disagreements with the favourite, so the disagreed subset fills
  more slowly.

### 1.2 Tighten the selection gates

**Owner: Claude runs the sweep; Ben decides. Sweep, plus one small tunable.**

The 8% probability floor and 5% edge threshold are stated as unfitted starting
points. Sweep `minimumValueProbability ∈ {0.08, 0.12, 0.15, 0.20}` ×
`minimumValueEdge ∈ {0.05, 0.10, 0.15}`. Read strike rate and ROI on both
arms from 0.3.

Add one tunable, `maximumValuePrice` (decimal odds, default none), so the
selector cannot reach for a 14/1 shot on thin edge whatever the floor. It is
a new field on `Weights`, so it needs: the Go struct, the Swift
`RatingWeights` with a **decodable default** (the kit's Codable is synthesised,
so a required field would break decoding of every stored weight set and every
cached record), the parity golden regenerated, and a row on the Model tab.

- Pros: directly targets strike rate; cheap; reversible; the probability
  model and its log loss are untouched, so calibration stays measurable.
- Cons: fewer disagreements, so ROI likely falls and the agree/disagree split
  grows slower.

### 1.3 Record the decision

`docs/algorithm.md`'s back-test log gets a row per promoted set: date, change,
model and market log loss, both arms' strike rates, favourite strike rate,
race count. Quote the race count every time; a number without one is a vibe.

---

## Phase 2 — use what the server already holds

The server keeps every card, every result and every gzipped provider payload.
Three factors at zero weight and one new one can come off the archive with no
new provider. All of them need the corpus to fill first, and all of them are
subject to the back-test's own leakage note: strike-rate factors read today's
archive, which knows results after each race, so a back-test that weights them
is optimistic. Build them to read the archive **as of the seal time** so the
replay is honest.

### 2.1 Trainer and jockey strike rates

**Owner: nobody, then Claude. Waiting on data.**

Already implemented and gated at n ≥ 30 per trainer or jockey, Laplace-smoothed
towards the race mean. Nothing to build until the archive fills; the Model tab
reports them as *waiting*. When enough are live, the nightly trainer can weight
them, since `commonFactorIDs` fits whatever the snapshots carry. The one code
item is the as-of-seal read above, so the back-test does not see the future.

### 2.2 A draw-bias table from the archive

**Owner: Claude. Medium. Server only.**

There is no draw-bias provider in Go; `Draw` ships at zero with no table to
read. Build a nightly job over flat results: bucket by course × distance band
× field-size band, compute each stall third's win rate against expectation,
and write the table as a document with per-cell sample sizes. `DrawFactor`
reads it and stays neutral below a per-cell floor (30 races). Draw is a
course × distance × going × field-size interaction, so this takes a full flat
season before most cells clear the floor; Racing Alpha's `get_draw_bias`
(`docs/data-sources.md`) is the only free shortcut, licence permitting.

### 2.3 Class-adjusted form from archived cards

**Owner: Claude. Large. Server only. The biggest free win.**

The free form string says a horse won and not in what. A Class 7 seller and a
Group 1 both read `1`. `docs/algorithm.md` says the form factor is written to
consume richer history when present; in Go it is not, so this is a build.

Every card the server stores carries `raceClass`, `distance`, `going` and
`type`, and every result carries positions and starting prices. From the day
the server started, each horse's runs *that the server has seen* can be joined
into a history with class, field size, SP and finishing position. A
class-aware form score then weights a win by the class it came in and a
beaten position by the price it went off at. Horses with no seen runs fall
back to the string, exactly as today, so it degrades to the current model on
day one and improves with every card.

- Pros: attacks the model's main stated weakness; free; improves monotonically.
- Cons: cold start measured in months, and with paid data ruled out there
  is no shortcut round it; two form paths to keep honest; needs the
  as-of-seal rule above or the replay leaks.

### 2.4 Market movement between draft and seal

**Owner: Claude. Medium. Server only.**

Late money is a real signal in UK racing. The server prices every race every
fifteen minutes from 06:00, but `SaveSnapshot` keeps only the latest
`display` snapshot per race. The time series is still recoverable: every
`listMarketBook` response is gzipped in `raw_payloads` with its fetch time.

Build a `marketMove` factor: the change in de-vigged implied probability
between the first priced draft of the day and the seal, standardised within
the race. Frozen at seal like every other factor. It is a new `FactorID`, so
the kit needs its `label`, `summary` and `rationale` or
`FactorDescriptionTests` fails, and the parity golden is regenerated.

Cheaper first step: stop deleting the earlier display snapshots, so the
series is a table rather than a decompression.

---

## Not on the table — paid data

**Decided 2026-09-25: no paid data sources.** The Racing API's Basic tier
would have added Racing Post Rating and Topspeed per runner, and RPR is the
strongest single public predictor of a UK race after the market itself. The
domain already carries slots for both, so the plumbing exists if the decision
is ever reversed, but nothing in this plan depends on it.

What that decision costs, so it is a known cost rather than a surprise:

- The class-blindness of free-tier form has one free fix, item 2.3, and it
  takes months to fill rather than an afternoon. Item 2.3 is therefore the
  spine of Phase 2, not one option among several.
- Market movement (2.4) becomes the second-strongest free signal and moves up
  the order accordingly.
- The archive is the only source of anything the market does not already
  know. Every day the server runs is a day of that archive; a day it misses
  is gone, which makes the `races.db` backup in the roadmap part of this plan
  rather than housekeeping beside it.

`docs/data-sources.md` already rules out every runtime provider other than the
two in use; the one free reference table it would admit is Racing Alpha's
draw bias, licence permitting, for item 2.2.

---

## Phase 4 — let training reach the levers

**Owner: Claude. Large. Server only. After Phase 1 and the 500-race corpus.**

Nightly training refits factor weights, α and β only. The form points table,
the decay, the de-vig method and both selection thresholds are excluded, and
those are where the strike-rate levers are. They cannot be fitted from frozen
snapshots, because changing them changes the z-scores; they need the re-rated
corpus the back-test already walks.

Extend the nightly job with a second stage over the sealed-race corpus: a
coordinate-descent sweep on a discrete grid over `formPoints`, `formDecay`,
`overroundMethod` and the selection gates, scored on the same held-out newest
races, promoted under the same rule (log loss must not worsen by more than the
bar in `docs/algorithm.md`; then the chosen objective from the top of this
document must improve). Same `weightsID` discipline: a promotion mints an id.

This is the point at which "improve the strike rate" stops being a sequence of
manual sweeps and becomes something the server does to itself, which is what
`docs/on-device-learning.md` promised.

---

## Order of work

| # | Item | Needs | Effort | Who |
|---|---|---|---|---|
| 1 | 0.1 Same denominator on the Record tab | nothing | S | Claude |
| 2 | 0.2 Wilson interval on screen | nothing | S | Claude |
| 3 | 0.4 Install a weight set | nothing | S | Claude |
| 4 | 0.3 Second arm, sweep shape, script | nothing | M | Claude |
| 5 | 2.4 (first step) keep every display snapshot | nothing | S | Claude |
| 6 | 1.1 Power de-vig sweep | ~200 sealed races, 0.3 | run | Claude, Ben decides |
| 7 | 1.2 Selection gate sweep + `maximumValuePrice` | 0.3, 1.1 | S + run | Claude, Ben decides |
| 8 | 2.1 As-of-seal archive reads | nothing | S | Claude |
| 9 | 2.3 Class-adjusted form | 8 | L | Claude |
| 10 | 2.4 `marketMove` factor | 5 | M | Claude |
| 11 | 2.2 Draw-bias table | a flat season | M | Claude |
| 12 | 4 Training over the re-rated corpus | 500 races, 7 | L | Claude |

Items 1 to 5 and 8 can go in now, in one or two PRs, while the corpus fills.
Items 6 and 7 are the first that change what the app tips, and they are the
ones most likely to move strike rate quickly. Items 9 and 10 are where the
model can learn something the market has not already priced, and with paid
data off the table they are the ceiling on what this plan can reach.

## What would make me stop

- The power method or the tighter gates raise strike rate but push model log
  loss above the market's plus 0.005. That is the model being made worse to
  look better, and `docs/algorithm.md`'s bar exists to catch it.
- The highest-probability arm beats value selection on ROI as well as strike
  rate over a few hundred races. Then value selection is not earning its keep
  and should be switched off, not tuned.
- The model's interval never separates from the favourite's after the corpus
  reaches a few hundred races and items 9 and 10 are live. Then the honest
  answer is that the free-tier factors do not add to the market. The model
  should then run market-only, and the app's value is the record it keeps,
  not the picks.
