# Provider Reference

Every third-party endpoint this app calls, what tier it needs, and what we take
from it. **Keep this in step with `ios/RacesKit/Sources/RacesKit/Providers/` — if
you add, remove or re-tier a call, update this file in the same change.**

This matters more than a normal API doc would, because we don't own these APIs and
**the free/paid boundary is invisible until a 403 arrives at runtime**. This file
is the map of that boundary.

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
- **Usecase:** The full list of British and Irish courses. Backs the Courses tab.
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

### Betting — `/exchange/betting/rest/v1.0`

All calls are `POST` with a JSON body.

#### `listMarketCatalogue`
- **Usecase:** Today's GB win markets with per-runner metadata — a free second
  racecard, and the join target for our Racing API cards.
- **Filter:** `eventTypeIds: ["7"]` (Horse Racing), `marketCountries: ["GB"]`,
  `marketTypeCodes: ["WIN"]`, a `marketStartTime` range.
- **`marketProjection`:** `RUNNER_METADATA`, `MARKET_START_TIME`, `EVENT`
- **Metadata consumed:** `CLOTH_NUMBER` (the join key), `FORM`,
  `DAYS_SINCE_LAST_RUN`, `OFFICIAL_RATING`, `ADJUSTED_RATING`, `WEIGHT_VALUE`,
  `STALL_DRAW`, `JOCKEY_NAME`, `TRAINER_NAME`, `WEARING`, `COLOURS_FILENAME`
- **Note:** `maxResults` is required and capped; page through a day by start time.

#### `listMarketBook`
- **Usecase:** Current back/lay prices → implied probability, the model's anchor.
- **Batching:** up to 40 market ids per call — respect this, it is a hard limit.
- **Caching:** 5 minutes.

#### Betfair SP
- **Usecase:** Settled starting price → ROI to level stakes in the tracker.
- **Source:** `listMarketBook` with `priceProjection.priceData` including `SP_TRADED`
  after the off, read once a market is settled.

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
