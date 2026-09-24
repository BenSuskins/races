# On-device model learning

> **Now server-side.** Since 2026-09-24 this trainer runs on the Races server
> (`server/internal/training`, a line-for-line port) every night at 03:00 over
> every settled race the server has sealed, plus any samples a phone uploaded.
> The rules below — the 500-race minimum, held-out validation, promotion only on
> improvement, a new `weightsID` on promotion — are unchanged. A promoted set is
> stored in the `weights` table and becomes active; `GET /v1/model` shows it.


The app can refit its rating weights entirely on the device from races it has already
seen and settled.

## When it learns

The default configuration waits for **500 complete, market-anchored settled races**.
It then trains on the most recent 2,000 races, holding out the newest 100 as a
walk-forward validation set. Another training pass is considered after each further
500 settled races.

A race is only eligible when the complete field, market probabilities and winner are
known. Truncated result payloads, non-runners and form-only races do not teach the
market-anchored learner.

## What it learns

The optimiser learns:

- the relative weights of the available rating factors;
- `marketExponent` (alpha);
- `formInfluence` (beta).

It minimises multiclass log loss with L2 regularisation toward the currently active
weights. Factor weights are constrained to be non-negative and to retain their
existing total weight. Alpha and beta stay inside conservative configurable bounds.

## Promotion rule

A candidate is **not** installed merely because training found a lower training loss.
The candidate must beat the current weights on the held-out validation races by at
least `minimumImprovement` (default 0.002 log-loss).

If it fails that test, the current model remains active and the sample count is still
advanced. The same data therefore cannot cause repeated retraining on every launch.

Every promoted set gets a new `weightsID`, and the active weights are persisted in
Application Support. The next launch resumes with the learned model.

## Why the snapshot is frozen

At tip time the app stores the market probabilities and every factor's z-score. The
winner is deliberately **not** stored until the result settles. This means the
training sample contains exactly what the model knew before the race, paired with the
outcome it learned later.

The snapshot is persisted locally as part of `training.json`; no server or external
training service is involved.

## Relationship to value-aware selection

The probability model remains separate from the selection policy. The selection layer
already uses the model's expected-value edge at the available back price, with a
minimum probability floor to avoid tiny-probability longshots dominating on price alone.

Learning changes the probability model only when it demonstrates an out-of-sample
log-loss improvement. It does not force the app to select outsiders, and it does not
optimise directly for tip strike rate or short-term ROI.
