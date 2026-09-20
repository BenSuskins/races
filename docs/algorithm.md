# The Rating Algorithm

How a winner is picked, why it is built this way, and — importantly — what it
cannot do. Keep this honest; it is the document that stops the app fooling us.

## The shape of it

```
FormScore_i = Σ_f  w_f · z_{f,i}                  z clipped to ±clip
s_i         = p_market_i ^ α  ·  exp(β · FormScore_i)
p_i         = s_i / Σ_j s_j
```

- `p_market_i` — the exchange's implied probability for runner *i*, with the
  overround removed.
- `z_{f,i}` — factor *f* for runner *i*, standardised **within the race**. Absolute
  scales mean nothing across races; a rating of 82 is strong in a Class 6 and weak
  in a Group 2.
- `α` — how much to trust the market's shape. Default `1.0`.
- `β` — how far we allow ourselves to disagree with the market. Default `0.35`.

### Why this form

Probabilities stay in (0,1) and sum to 1 by construction, and every factor is a
clean multiplicative nudge.

But the property that actually matters is this: **at `β = 0` the model reproduces
the market exactly.** The model can therefore never be accidentally worse than its
own anchor without that being visible, and the central question — *is any of this
doing anything?* — becomes a measurement rather than an opinion. The back-test
asserts `logLoss(model) ≤ logLoss(market) + 0.005`. If a weight change breaks that,
CI says so.

Most tipping algorithms cannot answer that question about themselves. This one can,
by construction. That is the single best property of the design and it is worth
protecting.

### No market

When Betfair is unconfigured, or a race can't be matched confidently, `p_market`
becomes uniform (`1/n`) and `β` rises to `formInfluenceNoMarket` (default `0.90`).
The UI shows a *form only — no market data* badge and drops confidence one band.

This is a first-class path, not an error state. It is also built and exercised
**before** the Betfair integration, so it is genuinely tested rather than a
theoretical fallback.

## Removing the overround

Raw implied probability is `1 / backPrice`. The exchange book sums to roughly
1.01–1.05; proportional normalisation divides each by the sum.

> **Known weakness.** Proportional de-vigging spreads the overround evenly, but it
> is not evenly distributed — the favourite–longshot bias concentrates it on the
> outsiders, so this method systematically over-prices longshots. The power method
> (solve for *k* such that `Σ pᵢ^k = 1`) corrects for it.
>
> Both are implemented. Proportional is the default because it is trivially
> correct and easy to test. Switching is one field on `FactorWeights`. Flip it when
> the back-test shows it improves log loss, not before.

**Price source priority:** back/lay mid → back → last traded → forecast.

That last fallback matters more than it looks. Tomorrow's markets have little or no
liquidity, so for `day == .tomorrow` the anchor is usually the Betfair *forecast*
price. `MarketSnapshot.source` records which was used and the UI says "forecast
prices" rather than implying a live market.

Forecast price is never a separate factor — it correlates ~0.95 with the live
market, so including both would be double-counting.

## Factors

All weights live in `FactorWeights` (`Rating/FactorWeights.swift`), the one tunable
place, `Codable` so the back-test can sweep them.

| Factor | From | Weight | Confidence |
|---|---|---|---|
| Official rating | `ofr` | 0.30 | Solid |
| Handicap band position | `ofr` + `rating_band` | 0.20 | Solid, handicaps only |
| Recent form | `form` | 0.25 | Moderate — class-blind |
| Won last time | `form` | 0.10 | Moderate |
| Completion rate | `form` | 0.08 | Weak–moderate, jumps only |
| Days since last run | `last_run` | 0.06 | **Weak** |
| Age | `age` + `age_band` | 0.04 | **Weak** |
| Weight carried | `lbs` | 0.02 | **Dubious** |
| Draw | `draw` | **0.00** | **Dubious — off** |
| Headgear change | `headgear` + archive | 0.05 | **Dubious** |
| Trainer / jockey strike rate | own archive | **0.00** | **Off until n ≥ 30** |

Runners missing a value get `z = 0` — race-neutral. **Never impute a guess**; a
horse with no official rating is unknown, not average-by-assumption.

### The dubious ones, and why they are still here

Shipping these at zero with the code present is deliberate. Inventing numbers we
can't substantiate would produce confident nonsense, which is the worst possible
failure mode for an app that tells you what to back.

- **Weight carried.** In a handicap, weight *is* the handicapper's equaliser —
  higher weight means a better horse and the whole point is that it cancels out.
  "Less weight is better" is close to backwards; "more weight is better"
  double-counts official rating. 0.02 is a placeholder for the back-test to settle.
- **Draw.** Draw bias is real but it is a course × distance × going × field-size
  interaction. Without a bias table it is noise. Ships at 0.00 behind
  `DrawBiasProviding` with an empty default table. Once the archive holds enough GB
  flat results, an empirical table derived from the app's own data can fill it —
  and only then does the weight come off zero.
- **Headgear change.** The genuinely predictive signal is *first-time* headgear,
  which the free tier cannot express (`headgear_run` is paid). Detecting changes
  between days we happened to observe is a strictly weaker proxy with a cold-start
  problem.
- **Days since last run.** A real but small, non-monotonic effect, heavily
  confounded by trainer intent, which we cannot see.
- **Trainer / jockey strike rate.** Computing these from our own archive is
  legitimate but slow to become significant and badly biased early — a trainer with
  one win from one run is not a 100% strike rate. Laplace-smoothed toward the race
  mean with a hard n ≥ 30 gate.

## Form strings

UK convention: **the rightmost character is the most recent run.** `1-3241` means
the last run was a win.

Digits are finishing positions, `0` means tenth or worse. `P` pulled up, `U`
unseated, `F` fell, `R` refused, `B` brought down, `S` slipped up, `D` disqualified.
`-` separates seasons, `/` a longer gap.

Parsing is total: it never throws, unrecognised characters are skipped, and
`nil`/`""` yield zero runs.

Points are recency-weighted with geometric decay (0.75), with older runs discounted
further across a `-` and heavily across a `/`. The default points table
(`1 → 1.00, 2 → 0.72, 3 → 0.55 …`) is **hand-chosen, not fitted**. It lives in
`FactorWeights.formPoints` precisely so the back-test can refit it.

> ⚠️ **Verify the ordering against a live response before trusting the form
> factor.** Getting it backwards silently inverts the strongest form signal, and
> nothing else would look wrong. There is a fixture test pinning it: take a horse
> from the committed racecard whose recent record is known from the committed
> results file, and assert the last character matches the most recent run.

### The structural weakness of free-tier form

The string says a horse finished first. It does not say *in what*. A Class 7 seller
and a Group 1 both read `1`. Two runners showing `1-121` can be forty pounds apart.

This is the main reason the form weight stays modest and the market anchor
dominates — and it is exactly what the paid `/v1/racecards/{horse_id}/results`
endpoint fixes, since it carries class, starting price, beaten lengths and RPR per
run. The form factor is written to consume that richer history when present and
fall back to the string when not.

## Explaining a tip

Each factor's contribution is computed **leave-one-out**: recompute `p_i` with that
factor set race-neutral, and report the difference.

These deltas do **not** sum exactly to the total deviation from the market — the
renormaliser is nonlinear. So the UI labels them "effect on win chance" and shows
the market probability and the final probability as the two anchors, never implying
the middle rows add up. Pretending otherwise would be a small lie that compounds.

> **Kyprios** — 24% chance · fair odds 4.2 · available 5.5
> Market says 18%. Our factors move it to 24%.
> ↑ Official rating — OR 82, 8 lb above the race average · +4.1%
> ↑ Recent form — 1-121, won last time out · +2.8%
> ↓ Days since last run — 118 days off · −1.2%
> — Draw — not applied (no bias data for this course)

## Back-test log

Record every weight change here with its effect, so tuning is a trail rather than a
vibe. Roughly 150 fixture races is enough for regression testing and **nowhere near
enough for statistical inference** — say so whenever quoting a number from it.

| Date | Change | Model log loss | Market log loss | Strike rate | Favourite strike rate |
|---|---|---|---|---|---|
| — | `v1` baseline, not yet run | — | — | — | — |
