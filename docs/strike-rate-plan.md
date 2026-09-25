# Improving the strike rate

This plan improves the model's selection of winners without confusing a lucky
short record with evidence. It applies to the server model after `v3`, which
selects the runner with the highest model probability.

The favourite remains the control arm. Every change must beat it on the same
races without worsening model log loss beyond the existing `+0.005` limit.

Paid data remains out of scope. This makes the server's own archive the main
source of new information, and it makes archive timing a correctness rule.

## Rules before measurement

### Use the race as it existed at sealing

The current back-test loads the latest race card and the seal-time market
snapshot. A later card can remove runners or change fields, so this is not yet
a valid replay.

First store the complete card used at sealing, or reconstruct that card from
the recorded provider payloads. Store the seal-time going, surface, distance,
class, field, jockey, trainer, draw, and form for every runner.

Every historical feature must use only cards and results available before the
race sealed. Do not let a result update the feature used to predict that race.

### Measure the right populations

The Record tab currently compares all model tips with the favourite only where
a market favourite exists. Add a model subset over those same benchmarked
races. Display the shared denominator and the 95% Wilson interval for both
arms.

The interval belongs in the server report and API response, then in the Swift
model and Record tab. Regenerate the contract fixtures and test both layers.

Keep these populations separate:

- the current v3 chance picks;
- earlier v2 value picks;
- uploaded phone history;
- form-only tips without a market benchmark.

The Record tab must filter by `weightsID` and identify the active set. Do not
read a mixed headline as evidence for one model.

## Phase 0 — make the back-test trustworthy

### 0.1 Freeze the seal-time card

Add a seal-time card snapshot, or an equivalent reconstruction path from raw
provider payloads. Test that a later non-runner or card update does not change a
historical replay.

### 0.2 Add the honest Record report

Add the shared-denominator model subset, Wilson intervals, and clear weight-set
labels. Fix the uploaded-tip footnote so its count uses the displayed subset.

### 0.3 Compare both selection policies

The back-test currently reports one rerated model arm and the favourite arm. Add
explicit `highestProbability` and `valueSelection` arms over one shared race
set. Do not encode this as an accidental weight difference.

Add a sweep request with a base weight set and named field overrides. Return one
report per variant, with the race IDs or a stable shared-corpus identifier.

### 0.4 Install a tested weight set

Add an authenticated `POST /v1/admin/weights` endpoint. It must validate the
full weight set, mint a new immutable ID, record origin `manual`, and activate
the set. Never edit an ID already stamped on a tip.

### 0.5 Establish the control report

Record model and favourite strike rate, Wilson intervals, log loss, Brier score,
ROI, coverage, and race count for every back-test. Include the market log loss.

Do not promote a change from the live Record tab. Use the back-test first.

## Phase 1 — cheap model changes

Run each item through the Phase 0 sweep. Promote only when the chosen objective
improves and log loss stays within the control limit.

### 1.1 Compare de-vig methods

Sweep proportional and power-method de-vigging against the current weights. The
power method already exists as `overroundMethod: "power"`.

### 1.2 Re-measure v2 and v3

Compare value selection with highest-probability selection on the same races.
Report strike rate, ROI, log loss, agreement with the favourite, and sample size.

Keep v3 unless value selection earns a clear return benefit without an
unacceptable strike-rate loss.

### 1.3 Test gates without adding tunables

Sweep the existing value gates before adding new fields. Do not add a price cap,
confidence gate, or other threshold until a back-test shows that it earns its
place.

## Phase 2 — build the as-of-seal archive

The server already stores results, runner identities, jockeys, trainers, and
race attributes. The archive currently exposes global jockey and trainer
strike rates. It does not yet provide historical horse performance by ground.

Build features from an as-of-seal archive. Each feature must have a fallback,
a sample floor, shrinkage toward a sensible prior, and a neutral zero-weight
default until its replay passes.

### 2.1 Jockey and trainer performance

Keep the current global jockey and trainer factors as the first version. They
remain silent below 30 runs and shrink toward the archive baseline.

Then add time-aware measures only when the archive supports them:

- recent form over a defined number of days;
- performance by race type and surface;
- performance by going bucket;
- jockey and trainer combination performance.

Use only information known before sealing. A trainer's full current-season
record must not be used to rate an earlier race.

### 2.2 Horse performance by going

Add a `horseGoingPerformance` factor for a horse's record on broad going
buckets: firm, good, soft, heavy, and synthetic categories where supported.

Start with a shrunk win or place-rate signal. Require a minimum sample and fall
back to the horse's general form, then the field prior. Do not split immediately
by exact provider wording, course, distance, class, and surface. That would
create sparse cells and unstable weights.

Measure whether going-specific history adds information beyond the market and
recent form. A factor that only restates the market does not earn a weight.

### 2.3 Contextual jockey and trainer performance

After the global factors and horse-going factor have enough history, test
jockey-going and trainer-going effects. Test race type, surface, distance band,
and class only as separate candidate factors.

Use hierarchical shrinkage or a prior for every small cell. Require an
out-of-sample gain before enabling an interaction. Prefer one stable factor to
a large table of memorised rates.

### 2.4 Draw bias

Build the existing course × distance × going × field-size table. Keep a sample
floor for every cell and remain neutral below it. Expect a full flat season
before many cells become useful.

### 2.5 Class-adjusted form

Replace the class-blind form string with history that joins each horse's prior
runs to class, field size, starting price, distance, surface, and finishing
position. Fall back to the current form string when history is missing.

Keep this feature separate from ground performance so the sweep can show which
signal adds value.

### 2.6 Market movement

Keep every display snapshot, or reconstruct the series from raw Betfair
payloads. Add the change in de-vigged market probability between the first
priced draft and sealing, standardised within the race.

Freeze the value at sealing. Add the factor's label, summary, rationale, parity
fixture, and golden output before enabling it.

## Phase 3 — validate the history features

For each candidate factor, use a chronological walk-forward split:

1. build the feature from history before the race;
2. fit or select its weight on older races;
3. evaluate on newer sealed races;
4. compare against the market, favourite, and current model.

Report the number of races, the number of non-neutral samples, coverage, log
loss, Brier score, strike rate, and ROI. A higher strike rate alone is not a
promotion rule.

Check performance by going bucket, season, race type, and market coverage.
Reject a feature that works only in one thin bucket or only on the training
period.

## Phase 4 — let training reach safe levers

The current trainer fits factor weights, market exponent, and form influence.
It does not refit form points, decay, de-vigging, or selection policy.

After the archive and replay are sound, add a discrete walk-forward sweep for
those levers. Keep the existing 500-race floor, held-out validation, promotion
threshold, and new `weightsID` on promotion.

Do not let nightly training choose a contextual factor before that factor has a
sample floor and a leakage-safe replay.

## Order

| Order | Work | Dependency |
|---:|---|---|
| 1 | Freeze the seal-time card | none |
| 2 | Shared benchmark, Wilson intervals, and weight-set Record view | 1 |
| 3 | Both selection arms and sweep API | 1 |
| 4 | Manual weight installation | 3 |
| 5 | Power de-vig and v2/v3 measurement | 2–4 |
| 6 | As-of-seal archive | 1 |
| 7 | Global jockey and trainer factors | 6; existing code |
| 8 | Horse performance by going | 6; more history |
| 9 | Contextual jockey and trainer factors | 7–8; larger history |
| 10 | Draw bias and class-adjusted form | 6; seasonal history |
| 11 | Market movement | 1; retained snapshots |
| 12 | Training sweep over safe levers | 5–11; 500 races |

## Stop conditions

Stop or revert a factor when it worsens validation log loss beyond the market
limit, fails across time periods, or has too few non-neutral observations.

If ground, jockey, and trainer history add no out-of-sample information after a
full season, use the market-led model and record that result. More factors are
not evidence of a better model.
