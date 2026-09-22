# Races

UK horse racing for iOS. Browse **course → race → runner**, get an explainable
recommendation for each race, and see honestly how well those recommendations do.

Native SwiftUI, no backend. The app talks to two providers directly and keeps its
own history on device.

## Status

Everything in the original plan is built and on TestFlight. What is left, and what
each item is actually blocked on, is in [`docs/roadmap.md`](docs/roadmap.md).

| Milestone | State |
|---|---|
| M0 — package skeleton, core networking, CI | Done |
| M1 — Racing API client and browse | Done |
| M2 — Betfair market data | Done |
| M3 — rating engine and explanations | Done |
| M4 — tip ledger and accuracy tracking | Done |
| M5 — Betfair SP, so ROI has a price source | Done |
| M6 — the model on screen: every weight, and why | Done |

Two things are outstanding and neither is a feature: the **Betfair login spike**
(two minutes, on a device, and three merged changes depend on the answer), and
**real race days** — the archive starts empty, so the strike-rate factors, ROI and
the favourite baseline all need a sample before they mean anything.

See [`docs/providers.md`](docs/providers.md) for the data sources and
[`CLAUDE.md`](CLAUDE.md) for developer context.

## How the recommendation works

Short version: it starts from the betting market's own implied probability and
nudges it with the form factors available on the free data tier — official rating,
the form string, days since last run, and strike rates accumulated from the app's
own growing archive.

The nudge is a single bounded dial. Turn it to zero and the model reproduces the
market exactly. That is deliberate: it makes the one question that matters —
*does this beat simply backing the favourite?* — answerable rather than rhetorical,
and the accuracy tracker reports that comparison alongside every other figure.

Factors the free data tier can't support honestly (draw bias, first-time headgear)
ship at zero weight with the code present, rather than being faked with invented
numbers. See [`docs/algorithm.md`](docs/algorithm.md).

## Setup

You need your own credentials for both providers; nothing is bundled in the app.

1. **The Racing API** — a username and password from
   [theracingapi.com](https://www.theracingapi.com). The free tier is enough to run
   the app.
2. **Betfair** — an account plus a free *delayed* application key from the
   [Betfair Developer Program](https://developer.betfair.com). The delayed key runs
   against the live exchange with prices delayed 1–180 seconds, which is fine for
   ranking runners. The £499 activation fee applies only to the *live* key, which
   is for placing bets and which this app does not need.

Enter both in Settings. They are stored in the Keychain.

Betfair is optional — without it the app falls back to a form-only rating and says
so on screen.

## Development

```bash
swift test --package-path ios/RacesKit      # the fast loop; runs on Linux
```

The whole kit — networking, matching, rating, storage — is testable with no
network and no subscription, against committed fixtures. If a change can only be
tested with live credentials, the seam is in the wrong place.

## Not betting advice

A personal tool, for information only. Gambling involves risk; never stake more
than you can afford to lose. Support and advice: [BeGambleAware](https://www.begambleaware.org)
or the National Gambling Helpline on 0808 8020 133.

## Licence

MIT — see [LICENSE](LICENSE).
