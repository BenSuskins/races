# Matching the two providers

The app reads two feeds that describe the same afternoon's racing and never agree
about anything. The Racing API gives us races and runners; Betfair gives us
markets and selections. Nothing links them: no shared race id, no shared horse
id, no shared course id. The join has to be inferred.

This document records how, and — more importantly — what the matcher refuses to
do.

## Why a wrong match is worse than no match

When a race has no market the rater falls back to form only, labels itself as
having done so, and the UI says prices are unavailable. The user knows exactly
what they are looking at.

When a race has the **wrong** market, every runner's probability is anchored to
another race's prices. The output looks completely normal: probabilities sum to
one, the favourite has a short price, the factor breakdown reads sensibly. There
is nothing on screen to suggest anything is wrong, and the tip that comes out of
it enters the accuracy record as if it meant something.

So the matcher is built to refuse. Every threshold below is set where it is
because the cost of a false positive is much higher than the cost of a false
negative.

## What has to agree

| # | Signal | Source | Tolerance |
|---|---|---|---|
| 1 | Course | `Race.courseName` vs `Event.venue` | Exact, after normalisation |
| 2 | Scheduled off | `Race.offDateTime` vs `marketStartTime` | ±6 minutes |
| 3 | The horses | runner names vs selection names | ≥ 60% of our declared field |

### 1. Course

`CourseNameNormaliser` reduces both names to a comparison key. The providers
differ consistently rather than randomly: the Racing API uses official names
(`Catterick Bridge`, `Great Yarmouth`, `Epsom Downs`), Betfair uses short ones
(`Catterick`, `Yarmouth`, `Epsom`).

Only decoration is removed — trailing `Park`, `Downs`, `Bridge`, `City`,
`Racecourse`; leading `The`, `Great`; anything in brackets; and everything from
an `-on-` onwards, which handles `Bangor-on-Dee` and `Stratford-on-Avon`.

`royal` is deliberately **not** droppable: `Down Royal` is a course, and dropping
the word would leave `down`.

The safety net is a test, not the rule list. `test_noTwoRealCoursesShareAKey`
runs every British and Irish course through the normaliser and asserts the keys
stay distinct. A rule that collapsed two real courses would let one meeting be
priced off another's market, so no normalisation rule is acceptable unless that
test still passes.

### 2. Time

Six minutes, not the two first proposed. The feeds disagree by more than you
expect: the Racing API publishes the advertised off, while Betfair's
`marketStartTime` follows the card as it is re-timed through the afternoon. Two
minutes loses real matches after a delay; six is still comfortably inside the gap
between consecutive races at one course, which is the only thing the window has
to avoid crossing.

Time is the **weakest** of the three signals and is used only to narrow
candidates and to break ties.

### 3. The horses — and why this one counts names only

This is the check that makes the other two safe, and the subtle part of the whole
design.

Course and time can both agree and still be the wrong race. Newmarket's July
Course and Rowley Mile normalise to the same key, because Betfair calls both of
them `Newmarket`. A re-timed card can put two races minutes apart. An abandoned
meeting's markets linger. In each case the only thing that distinguishes "this
race" from "a race that looks like it" is which horses are in it.

**Saddle cloth numbers cannot do this job.** Every race numbers its runners from
one, so cloths agree between *any* two races of the same size. A matcher that
paired runners on cloth number while deciding which market a race belongs to
would score a completely unrelated market at 100% overlap and accept it with
total confidence. That is the single worst failure this component can have, and
it is an easy one to write by accident.

So matching runs in two phases:

1. **Identify the market** by name evidence alone — exact normalised names, then
   a typo-sized fuzzy fallback. The ≥ 60% threshold applies to this figure,
   reported as `nameEvidence`.
2. **Then** re-match the winning market with cloth numbers enabled, to pick up
   the runners whose names one feed spells differently. This is where
   `CLAUDE.md`'s "cloth number first, names are the fallback" rule applies — it
   is a rule about identifying *runners within a race*, not about identifying
   the race.

`test_clothNumbersAloneCannotIdentifyARace` pins phase 1;
`test_clothNumbersFillInRunnersOnceTheMarketIsSettled` pins phase 2.

## Matching runners

Three passes, each over what the previous left:

| Pass | Basis | Notes |
|---|---|---|
| 1 | `CLOTH_NUMBER` vs `number` | Primary key. Skipped during phase 1 |
| 2 | Exact normalised name | Country suffix and cloth prefix removed |
| 3 | Levenshtein ≤ 2 | Last resort, ties refused |

`HorseNameNormaliser` strips Betfair's two display conventions — a cloth prefix
(`3. Kyprios`) and a country of breeding (`Kyprios (IRE)`) — then reduces to
uppercase letters and digits. Punctuation goes because the feeds disagree about
apostrophes: `'`, `’`, or omitted.

Two guards are worth knowing about:

- **A contradicted cloth number is refused.** The feeds can disagree about
  numbering after a withdrawal. If a cloth pairing's exchange name is
  unambiguously a *different* one of our runners, the numbering is what to
  distrust, and the pairing is dropped so the name passes can get it right.
- **No pass may produce a many-to-one pairing.** If two runners both near-miss
  the same selection, neither is used. The same price on two horses is worse
  than no price on either.

The fuzzy limit is two edits — typo-sized — because horses in one race can have
genuinely similar names. `test_genuinelySimilarNamesInOneRaceStayApart` shows
`MISTERMAN`/`MISTERMEN` and `SEAOFCLASS`/`SEAOFGLASS` sitting inside a limit of
two, which is why that pass runs last and refuses ties rather than guessing.

## Refusals are reported, not swallowed

`MatchReport` carries a `MatchRefusal` per unmatched race, because the reasons
mean different things:

| Refusal | What it usually means |
|---|---|
| `noCandidate` | Betfair isn't covering that meeting. Nothing to fix |
| `noOverlap` | **The matcher may be wrong.** Worth investigating |
| `ambiguous` | Two markets fit equally; refused on purpose |
| `noOffTime` | Our card is missing a time |
| `noRunners` | Nothing declared yet |

`matchRate` is the figure to watch. A drop means the join has regressed, and
`noOverlap` climbing is the specific shape of that regression.

## Known limitations

- **One market per race.** Whichever race claims a market keeps it; a second race
  wanting the same market is refused rather than given a duplicate. Races are
  processed longest-field-first so the most confident match resolves first.
- **Non-win markets are not filtered here.** Place and match-bet markets should
  be excluded before they reach the matcher. They will usually fail the overlap
  check anyway, but relying on that is luck rather than design.
- **No fixture pairs yet.** The tests are hand-built. Real paired captures — a
  Racing API card and the corresponding Betfair catalogue for the same
  afternoon — would be worth more than any of them, and are blocked on
  credentials for both providers.
