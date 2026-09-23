# On-device model learning

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

## What this does not do

The learner does not optimise for tip strike rate or force the app to select outsiders.
The probability model remains the probability model. The existing value-aware
selection layer consumes those probabilities separately.

The learner also does not blindly replace the market. The market remains the baseline,
and validation has to show a measurable out-of-sample improvement before a new set of
weights is promoted.
