# Provider Reference

Every third-party endpoint this app calls, what tier it needs, and what we take
from it. **Keep this in step with `ios/RacesKit/Sources/RacesKit/Providers/` — if
you add, remove or re-tier a call, update this file in the same change.**

This matters more than a normal API doc would, because we don't own these APIs and
**the free/paid boundary is invisible until a 403 arrives at runtime**. This file
is the map of that boundary.

`scripts/capture-fixtures.py` calls the free-tier endpoints below and writes
their replies as redacted test fixtures. If you change an endpoint here, change
it there too — it is the one other place in the repo that names these paths.

Conventions for the examples below:

```bash
export RACING_USER=...            # The Racing API dashboard username
export RACING_PASS=...            # The Racing API dashboard password
export BF_APP_KEY=...             # Betfair delayed application key
export BF_TOKEN=...               # Betfair session token from /api/login
```

---

## The Racing API — `https://api.theracingapi.com`

**Auth:** HTTP Basic (`Authorization: Basic base64(user:pass)`).
**Current tier: Free.** Credentials are entered by the user in Settings and held in
the Keychain; nothing is bundled in the app.

> **Naming trap.** The endpoint names are inverted relative to the tier names:
> `/v1/racecards/free` returns the *Basic* schema, and `/v1/racecards/basic`
> returns the *full* one. Read the tier column, not the path.

### Endpoints in use

#### `GET /v1/courses`
- **Usecase:** The full list of British and Irish courses. Backs the course
  directory, pushed from the Racing tab (it stopped being a tab of its own when
  the Model tab took the fifth slot).
- **Tier:** Free · **Rate limit:** 1 req/s
- **Fields consumed:** `id`, `course`, `region_code`, `region`
- **Caching:** Indefinite. Courses do not change.

```bash
curl -s -u "$RACING_USER:$RACING_PASS" \
  "https://api.theracingapi.com/v1/courses?region_codes=gb"
```

#### `GET /v1/racecards/free`
- **Usecase:** Today's and tomorrow's cards — the spine of the app.
- **Tier:** Free · **Rate limit:** 1 req/s
- **Race fields:** `race_id`, `course`, `date`, `off_time`, `off_dt`, `race_name`,
  `distance_f`, `region`, `pattern`, `race_class`, `type`, `age_band`,
  `rating_band`, `sex_restriction`, `prize`, `field_size`, `going`, `surface`,
  `race_status`
- **Runner fields:** `horse`, `horse_id`, `age`, `sex`, `colour`, `region`,
  `sire`/`dam`/`damsire` (+ ids), `trainer`/`trainer_id`, `owner`/`owner_id`,
  `number`, `draw`, `headgear`, `lbs`, `ofr`, `jockey`/`jockey_id`, `last_run`,
  `form`
- **Caching:** 15 minutes. Cards themselves barely change, but non-runners are
  declared through the day.

```bash
curl -s -u "$RACING_USER:$RACING_PASS" \
  "https://api.theracingapi.com/v1/racecards/free?day=today&region_codes=gb"
```

#### `GET /v1/results/today/free`
- **Usecase:** Reconciling tips against outcomes, and growing the on-device archive.
- **Tier:** Free · **Rate limit:** 1 req/s
- **Runner fields:** `horse_id`, `horse`, `position`, `number`, `draw`, `weight_lbs`,
  `headgear`, `or`, `jockey_id`, `trainer_id`
- **Note:** **No starting price.** ROI therefore comes from Betfair SP, not here.
- **Caching:** Permanent once a race is settled; appended to the archive.

```bash
curl -s -u "$RACING_USER:$RACING_PASS" \
  "https://api.theracingapi.com/v1/results/today/free"
```

#### `GET /v1/racecards/{horse_id}/results`
- **Usecase:** A horse's past runs, with the going, trip, class, field size and
  beaten margin the form string lacks. Feeds the deep-form rating factors.
- **Tier:** **Basic (paid)** · **Rate limit:** 5 req/s
- **Called anyway, once.** `RacingAPIClient.formHistory(horseID:)` attempts it. On
  the free tier the first call returns 403, `ProviderCapability` narrows, and every
  later call short-circuits to `APIError.tierUnavailable` **without touching the
  network** — twenty runners would otherwise mean twenty 403s, each burning a
  rate-limit slot a useful request could have had.
- **This is the whole upgrade path.** Subscribe to Basic and the same call starts
  succeeding, capability widens, and the deep-form factors activate with no change
  at any call site.

```bash
curl -s -u "$RACING_USER:$RACING_PASS" \
  "https://api.theracingapi.com/v1/racecards/hrs_1/results"
```

### Endpoints deliberately NOT used (paid tiers)

Listed because the code is built to light them up, and because the gap between
them and the free tier is the single biggest limitation on tip quality.

| Endpoint | Tier | What it would unlock |
|---|---|---|
| `/v1/racecards/basic` | Basic | Full racecard schema: `rpr`, `ts`, `spotlight`, `comment`, `trainer_14_days`, `going_detailed`, `stalls`, `weather`, `silk_url` |
| `/v1/results` | Standard | Historical results with `sp_dec` — ROI without needing Betfair |
| `/v1/horses/{horse_id}/results` | Pro | Full career history rather than just runners on an upcoming card |
| `/v1/jockeys/{id}/analysis/*`, `/v1/trainers/{id}/analysis/*` | Standard | Strike rates by course/distance. We approximate these from our own archive instead. |

When a paid endpoint is reachable, `ProviderCapability` widens and the extra rating
factors activate. Until then `formHistory(horseID:)` throws
`APIError.tierUnavailable`, which the rater treats as normal.

For sources outside these two providers — evaluated, and in every case so far not
adopted — see [`docs/data-sources.md`](data-sources.md). That file holds verdicts;
this one holds call sites. A source crosses over only when a call site exists.

---

## Betfair Exchange — `https://api.betfair.com/exchange/betting/rest/v1.0`

**Auth:** two headers on every call — `X-Application: <appKey>` and
`X-Authentication: <sessionToken>`.
**App key: the free *delayed* key.** It runs against the live production exchange
with prices delayed 1–180 seconds. That is fine here: we are ranking runners, not
trying to get on at a price. The **£499 activation fee applies only to the live
key**, which is for placing bets and which this app does not need.

### Identity — `https://identitysso.betfair.com`

#### `POST /api/login`
- **Usecase:** Exchange username + password for a session token.
- **Body:** `application/x-www-form-urlencoded`, `username` and `password`.
- **Header:** `X-Application: $BF_APP_KEY`
- **Returns:** `{"token": "...", "product": "...", "status": "SUCCESS", "error": ""}`
- **Caveat:** interactive login can be challenged by 2FA or CAPTCHA, which an app
  cannot transparently satisfy. If that proves common, the fallback is certificate
  login at `identitysso-cert.betfair.com/api/certlogin`.
- **Implemented by** `BetfairSession`. Note that a refusal arrives as **HTTP 200
  with `status: "FAIL"`** and the reason in `error`, so a status-code check reads
  it as a success with no token. `BetfairLoginFailure` keys off the body and
  classifies the code three ways, because they need different handling and
  different copy:

  | Class | Codes | What the app does |
  |---|---|---|
  | Bad credentials | `INVALID_USERNAME_OR_PASSWORD`, `INVALID_USERNAME`, `INVALID_PASSWORD` | Maps to `.unauthorized`. Retryable — the user can fix it. |
  | Needs a human | `SECURITY_QUESTION_REQUIRED`, `PENDING_AUTH`, `ACCOUNT_NOW_LOCKED`, `CHANGE_PASSWORD_REQUIRED`, … | Latched: not retried on every refresh, since that would look like a hang and could lock the account. |
  | Needs a certificate | `CERT_AUTH_REQUIRED`, `SECURITY_RESTRICTED_LOCATION` | Latched, and **this is the answer that reshapes the design** — it means a client TLS identity and a `URLSessionDelegate`. |

  The raw code is always preserved, so an unrecognised one is reported rather
  than collapsed into a generic failure. **Whatever the spike returns, the app
  will name it.**

  There is a **fourth class**, added after the spike was first run on a device
  abroad and the screen said only "We received an unexpected response. Please try
  again.": Betfair answering with something that is not a login reply at all.
  Every field of the response is optional, so any JSON object decodes — a decode
  failure here therefore means the body was not JSON. `logIn()` reads it raw and
  throws `BetfairLoginFailure.unreadableResponse(_:)` carrying status, content
  type, byte count and a redacted snippet.

  | Class | Codes | What the app does |
  |---|---|---|
  | Unreadable reply | `UNREADABLE_RESPONSE` (ours, not Betfair's) | Reports what came back instead; does **not** latch, and does not ask for the password again |

  A jurisdiction block, a captive portal and a corporate proxy all answer `200`
  with an HTML page, and the content type usually names which. Not latched,
  because unlike a 2FA challenge the cause is outside the account.

```bash
curl -s -X POST "https://identitysso.betfair.com/api/login" \
  -H "X-Application: $BF_APP_KEY" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "username=$BF_USER" --data-urlencode "password=$BF_PASS"
```

#### `POST /api/keepAlive`
- **Usecase:** Extend the session before it lapses.
- **Headers:** `X-Application`, `X-Authentication`.

> **Unverified:** the exact idle and absolute session lifetimes. Betfair's docs
> host is unreachable from the build environment, so these were not confirmed
> during design. Measure them in the M1 spike and record the answer here.
>
> The client does not depend on the answer. Rather than trusting a guessed
> expiry it renews **reactively** — when the exchange itself reports
> `INVALID_SESSION_INFORMATION`, the session is dropped and the call retried
> once. `BetfairSessionToken.keepAliveAfter` (4h, conservative against the
> commonly cited 12) only decides when a keep-alive is worth spending a request
> on. Correcting it later changes one constant and nothing else.

### Betting — `/exchange/betting/rest/v1.0`

All calls are `POST` with a JSON body.

#### `listMarketCatalogue`
- **Implemented by** `BetfairClient.markets(day:countries:)`.
- **Usecase:** Today's GB win markets with per-runner metadata — a free second
  racecard, and the join target for our Racing API cards.
- **Filter:** `eventTypeIds: ["7"]` (Horse Racing), `marketCountries: ["GB", "IE"]`,
  `marketTypeCodes: ["WIN"]`, a `marketStartTime` range. Ireland is included
  because the Racing API cards we match against are GB **and** IE, and a
  catalogue narrower than the card silently makes every Irish race form-only.
- **`marketProjection`:** `RUNNER_METADATA`, `MARKET_START_TIME`, `EVENT`
- **Metadata consumed:** `CLOTH_NUMBER` (the join key), `FORM`,
  `DAYS_SINCE_LAST_RUN`, `OFFICIAL_RATING`, `ADJUSTED_RATING`, `WEIGHT_VALUE`,
  `STALL_DRAW`, `JOCKEY_NAME`, `TRAINER_NAME`, `WEARING`, `COLOURS_FILENAME`
- **Caching:** 15 minutes, applied by `MarketLoader` in the app — the same
  window as a racecard, and for the same reason: the field changes through the
  day, but far more slowly than the prices do.
- **Note:** `maxResults` is required and capped; page through a day by start time.

#### `listMarketBook`
- **Usecase:** Current back/lay prices → implied probability, the model's anchor.
- **Batching:** up to 40 market ids per call — respect this, it is a hard limit.
- **Caching:** 5 minutes, applied by `MarketLoader` in the app, and **only for
  markets a race actually matched** — pricing the whole catalogue would spend a
  book call per forty markets on races we cannot join.
- **Implemented by** `BetfairClient.prices(marketIDs:)`, which batches at 40 and
  then **splits further on `TOO_MUCH_DATA`**. That code is an instruction rather
  than a failure: the same markets come back when asked for in smaller groups,
  so the batch is halved recursively. Surfacing it as an error would turn a
  recoverable condition into a card with no prices.
- **Faults arrive on a 200 as readily as on a 400.** Every betting call decodes
  the `detail.APINGException.errorCode` envelope speculatively, because mapping
  status codes alone lets an `INVALID_SESSION_INFORMATION` through as an empty
  array — and an empty array is indistinguishable from "no racing today".

#### Betfair SP
- **Usecase:** Settled starting price → ROI to level stakes in the tracker. The
  **only** source of one: `/v1/results/today/free` carries no starting price, so
  without this call the Record tab has a strike rate and no ROI, permanently.
- **Source:** `listMarketBook` with `priceProjection.priceData` including `SP_TRADED`
  after the off, read once a market is settled.
- **Implemented by** `BetfairClient.startingPrices(marketIDs:)`. An absent or
  zero `actualSP` is **omitted rather than defaulted**: a zero would read as a
  starting price and wreck the ROI figure, and a missing one just means the race
  has not settled yet.
- **Called by** `AppEnvironment.refreshResults()`, in the same pass as the Racing
  API results, for the market ids of tips still awaiting an outcome
  (`TipLedger.marketIDsAwaitingStartingPrice`). A settled BSP never changes, so a
  tip that has one is never re-requested, and a race that never matched a market
  is never asked about.
- **Not cached.** The two calls are independent: a failure here costs the ROI
  figure for those tips and nothing else, because the results pass settles them
  on the result alone. Losing the strike rate as well would be the bug, and the
  results endpoint is today-only so there is no second chance at it.
- **Keyed by selection id**, so `MarketReference` — frozen onto the tip when the
  match was made — is what turns the reply back into our horse ids. The catalogue
  that produced the match may be gone by the time a race settles, which is why
  the mapping is stored rather than re-derived.

---

## Rate limiting

Each provider gets its own `RateLimiter` (`Core/RateLimiter.swift`), since the
limits are unrelated.

| Provider | Limit applied | Why it is not a bottleneck |
|---|---|---|
| The Racing API | 1 req/s | The free tier is bulk-oriented: one call for today's cards, one for tomorrow, one for courses, one for results. Four calls covers a whole day. |
| Betfair | Conservative default | One `listMarketCatalogue` per day plus `listMarketBook` batched 40 markets at a time. |

The limiter is a safety net against a bug looping on a request, not a throughput
constraint we have to design around.
