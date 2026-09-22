# Roadmap

Everything in the original plan (M0–M6) is built and merged. What follows is the
work that is actually left, with the dependencies between the items made explicit
— because two of them look ready and are not.

Each item says **who owns it**, since several need a device, real credentials or a
billing decision rather than a commit.

Updated 2026-09-22.

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

**Owner: Claude. Depends on item 1 to mean anything.**

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

### 3. Real app icon

**Owner: Claude, or Ben if you have artwork.**

`scripts/make-app-icon.py` currently generates a placeholder.
`AppIcon.appiconset` needs a real 1024×1024 PNG **with no alpha channel** or App
Store Connect rejects the marketing icon.

Small, self-contained, and the only item here that Xcode Cloud verifies today.

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

Every item above is speculative until there is evidence the model does something.
A week of real cards produces more information about what to build next than any
of them.

One thing to watch while it runs: **if the Record tab shows no history after
updating**, that is the ledger-decoding path failing, and it is worth reporting
immediately rather than clearing and starting over.
