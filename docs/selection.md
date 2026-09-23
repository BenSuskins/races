# Value-aware tip selection

The probability model and the tip selection are deliberately separate.

## Why

The rating engine produces a calibrated probability distribution. The previous
selection rule simply returned the highest-probability runner, which meant a model
could disagree with the market but still recommend its favourite whenever that
favourite remained fractionally ahead.

The new selection layer asks a different question:

> Is there a meaningful positive expected value at the available Betfair back price?

The model probability remains unchanged, so log-loss and probability calibration
can still be measured independently of the selection policy.

## Value calculation

For decimal back odds `o` and model probability `p`:

```
valueEdge = p × o − 1
```

A value edge of `0.20` means the model estimates +20% expected return per unit
staked before commission, if the model probability is correct.

The market probability used by the rating engine is de-vigged first, so the model
is comparing its probability estimate with a margin-adjusted market reference.

## Selection policy

A priced runner is eligible to replace the normal highest-probability selection
when both conditions hold:

```
valueEdge >= 5%
winProbability >= 8%
```

Among eligible runners, the largest value edge wins. If two runners have the same
edge, the higher model win probability wins.

If no runner clears both gates, the selection falls back to the highest-probability
runner. With no usable market at all, selection is always the highest-probability
runner.

The 8% probability floor is intentional: without it, a tiny-probability longshot
can produce a very large EV number from a large price and dominate selection. The
5% EV threshold also avoids treating small numerical differences around zero as a
meaningful disagreement with the market.

These thresholds are starting points, not fitted claims. They should be compared
with the existing favourite baseline in the back-test before being changed.

## Example

| Runner | Model probability | Back price | Value edge |
|---|---:|---:|---:|
| Favourite | 40% | 2.20 | −12% |
| Value runner | 30% | 4.50 | **+35%** |
| Longshot | 4% | 30.0 | +20% |

The value runner is selected. The longshot has a positive EV calculation but fails
the 8% probability floor.

This is a selection decision, not a claim that the value runner is certain to win.
The back-test remains the authority for whether this policy actually improves
outcomes over a meaningful sample.
