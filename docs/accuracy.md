# Accuracy Tracking

What the tracker measures, what it deliberately refuses to measure, and the
limitations you should know about before quoting any number from it.

The purpose of this document is to make it hard for the app to flatter itself.

## The sealing rule

A tip is a **draft** until the race is close, and **immutable** afterwards:

| When | What happens |
|---|---|
| More than 5 minutes before the off | Recomputes overwrite the draft |
| Within 5 minutes of the off | The first write **seals** the record |
| After the off | **Nothing is recorded at all** |

A race first opened after it has run never enters the tracker. Without that rule
the tracker would measure what the model thought once the results were already
in — which is worth nothing, and would look impressive while being worth nothing.

The model version, the weights id and the full factor breakdown are frozen into
each record. Re-deriving a tip later would measure today's model against
yesterday's races.

## Denominators, and why there are several

**Strike rate** counts wins over `wins + losses`.

- **Non-runners and abandonments are void**, excluded from the denominator
  entirely. Counting a withdrawn horse as a loss marks the model down for a race
  it had no part in.
- **Unresolved and expired tips are excluded too** — but they are counted and
  shown, as a **coverage** percentage. A record built from a biased subsample must
  not be able to pass as a complete one.

**ROI to level stakes** counts a different set of races, because it needs a
starting price and many races will not have one. Those are excluded from ROI
while still counting toward strike rate, and the count is reported as
`settledWithoutPrice`. Blending the two denominators is how tipping records
quietly overstate themselves.

### Where the starting price comes from

**Betfair SP, and nothing else.** The free Racing API results endpoint carries no
starting price at all, so a tip's price exists only if its race matched a Betfair
market. Three consequences worth stating plainly:

- **ROI is a subset of strike rate, structurally**, not by accident. Every
  unmatched race and every race run without Betfair configured has a strike-rate
  outcome and no price.
- **That subset is not random.** A race fails to match when its field is unusual,
  its market is thin, or two meetings share a course — so the priced subset is
  mildly biased toward ordinary, liquid races. `settledWithoutPrice` is on screen
  so the gap is visible rather than inferred.
- **The favourite baseline is priced from the same `MarketReference`** as the tip.
  If the tip could be priced and the baseline could not, every ROI comparison
  would flatter the model by construction — so the reference stores the whole
  field's selection ids, not just the selection's.

The mapping from Betfair's selection ids to ours is **frozen onto the tip** when
the match is made, because by the time a race settles the catalogue that produced
the match may be gone, and re-matching a race that has already run is guesswork
dressed as data.

ROI is **not displayed below 50 settled tips**. Level-stakes ROI over twenty bets
is noise, and showing it would invite exactly the wrong conclusion.

Commission defaults to Betfair's 5% base rate and is a user setting, since the
real rate varies with discount and points allowance.

The Record tab defaults to the active `weightsID` and can select earlier sets.
Each selection uses only tips with that ID. The all-tip model rate is separate
from the model and favourite rates over the same benchmarked races. The server
returns a 95% Wilson interval for both rates; the app shows it with the count.

## The three figures that keep it honest

**1. The favourite baseline.** What backing the market favourite would have done
over exactly the same races. A 32% strike rate sounds excellent until you learn
the favourite won 34% of them. This is the only honest answer to *is this
algorithm any good?*

**2. The agree/disagree split.** When the tip *was* the favourite, the model
contributed nothing to that race. All of its actual information is in the subset
where it disagreed — that is where it earns or loses its keep, and it is reported
separately.

**3. Calibration, not just strike rate.** A model saying 25% and hitting 25% is
*working*, even if the overround makes it unprofitable. Brier score and the gap
between predicted and actual are reported alongside.

## Known limitations

- **The free results endpoint covers today only.** If the app is not opened on
  the evening of a race day, those results are gone for good. Such tips go
  `unresolved`, are retried, and `expire` after 7 days or 10 attempts. They are
  excluded from the metrics and **counted in the coverage figure**, so the record
  never silently becomes a biased subsample.
- **Abandonment detection is weak.** `is_abandoned` is a paid field, so the
  reconciler takes abandonment as a flag from its caller rather than detecting it.
- **Background refresh is best-effort.** iOS grants `BGAppRefreshTask` when it
  feels like it, so evening reconciliation cannot be relied on.
- **Prices are delayed.** The free Betfair app key returns prices 1–180 seconds
  behind, so the price captured at sealing is indicative at best. This is exactly
  why Betfair SP is the basis for ROI rather than the price shown at tip time.
- **A truncated result payload** would settle every runner as a non-runner and
  wipe a day of tips, so a field of fewer than three is treated as "still looking"
  rather than as evidence.

## Readings

### 2026-09-22 — the first real one, form-only

One racing day, recorded before the Betfair login was working. Kept here because
the numbers are about to be cleared, and a day of real racing is not free.

| | |
|---|---|
| Settled | 34 |
| Won | 7 |
| Strike rate | 20.6% |
| 95% CI (Wilson) | **10.3% – 36.8%** |
| Predicted strike rate | 23.9% |
| Calibration gap | +3.3 pp overconfident (0.48 standard errors) |
| Brier score | 0.154 |
| Favourite baseline | **none** |
| Agree / disagree | 0/0 |
| ROI | none — no tip carried a `MarketReference` |

**Every tip was form-only, so there is no benchmark and there never can be.**
`agreesWithMarket` returns `nil` without a market favourite, and
`favouriteOutcome` needs `marketFavouriteHorseID`, which is frozen onto the tip
at sealing. No later Betfair connection can fill it in. The sealing rule is
working exactly as designed, and the cost of that is a day whose strike rate can
never be judged against anything.

So **20.6% means very little on its own.** The interval spans poor to excellent.
Quoted here as a record, not as a result.

The one figure with any signal in it is the Brier score:

| Forecast | Brier |
|---|---|
| The model | **0.1540** |
| Best possible constant (0.206 every time) | 0.1635 |
| What it actually said on average (0.239) | 0.1646 |

A skill of **+0.0095** over the best constant forecast — the model did put higher
probabilities on winners than on losers. It is a whisper at n = 34, and it is the
first evidence the algorithm does anything at all.

For scale on what a real answer costs: separating 20.6% from a 33% favourite
baseline at 95% confidence needs roughly **96 settled tips per arm**; from 30%,
roughly **162**.

### A note for whoever reads the next one

These 34 tips are about to be cleared rather than carried forward, and that is
deliberate. Form-only and market-anchored are not the same algorithm — at
κ > 0 the market is the anchor and form is the adjustment — so averaging them
produces a number describing neither. Carrying them would also have left the
model's strike rate computed over *these plus* the priced races while the
favourite's was computed over the priced races alone, which is precisely the
flattering asymmetry the three figures above exist to prevent.

## What "good" would look like

Beating the favourite on strike rate over a few hundred settled tips, with
calibration error near zero, and a disagree-subset ROI that is not worse than the
agree subset. Under a hundred tips, none of these figures mean much — and the app
should say so rather than render a number.
