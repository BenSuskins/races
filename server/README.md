# Races server

The backend for the Races app. One Go binary with one SQLite file, running as a
container on the homelab `docker` host and reachable at
`https://races-api.suskins.co.uk` from the LAN and over Tailscale.

It does everything the phone used to do on its own, on a clock rather than when
someone opens the app:

- fetches The Racing API cards and results and Betfair markets and prices;
- matches races to markets (refusing rather than guessing);
- rates every race, drafts a tip, and **seals it five minutes before the off**;
- settles tips against results and Betfair SP, building the accuracy record;
- keeps every provider response gzipped in `raw_payloads`, so a future model can
  use fields nobody parses today;
- retrains the weights nightly, and back-tests any weight set against history.

The app reads. It holds the server's address and an API token, nothing else.

## Layout

| Package | Job |
|---|---|
| `cmd/races-server` | Configuration, wiring, HTTP server, scheduler start-up |
| `internal/domain` | Race, Runner, RaceResult, MarketSnapshot… in the JSON shape RacesKit's Codable models use |
| `internal/rating` | The model: factors, form scoring, overround, the rater. A port of `RacesKit/Rating` |
| `internal/training` | Nightly re-fit, promoted only if it beats the current weights on held-out races |
| `internal/tracking` | Tips, the sealing rule, settlement, the accuracy report, the strike-rate archive |
| `internal/matching` | Course and horse normalisers, runner and race matchers |
| `internal/httpx` | Rate limiting, retry, status mapping, decode errors that say what arrived |
| `internal/racingapi`, `internal/betfair` | The two provider clients. **`docs/providers.md` must change with them** |
| `internal/store` | SQLite (pure-Go driver), migrations embedded |
| `internal/service` | The jobs and the timetable |
| `internal/importer` | Folds a phone's pre-server history into the database |
| `internal/backtest` | Replays history through any weights, against the market |
| `internal/api` | The HTTP API |
| `internal/parity` | Pins the Go rater to the Swift one while both exist |

## Configuration

Environment variables, supplied by Ansible from the vault
(`tasks/docker/races-server.yml` in the homelab repo):

| Variable | |
|---|---|
| `RACES_API_TOKEN` | **Required**, 16+ characters. The bearer token the app sends |
| `RACING_API_USERNAME`, `RACING_API_PASSWORD` | The Racing API. Without them the scheduler does not run |
| `BETFAIR_APP_KEY`, `BETFAIR_USERNAME`, `BETFAIR_PASSWORD` | Optional. Without them every tip is form-only, which is an ordinary state |
| `RACES_DB_PATH` | Default `/data/races.db` |
| `LISTEN_ADDR` | Default `:8080` |
| `RACING_API_BASE_URL`, `BETFAIR_IDENTITY_URL`, `BETFAIR_BETTING_URL` | Point at a fake |
| `RACES_SCHEDULER=off` | Serve without collecting |

## Timetable (Europe/London)

| When | Job |
|---|---|
| Start-up | Everything once |
| Every minute | Seal any race inside the five-minute window, pricing it first |
| Every 15 min, 06:00–22:59 | Today's card, markets, drafts |
| Hourly, 06:00–22:00 | Tomorrow's card, markets, drafts |
| Every 15 min from 12:00, and 23:55 | Today's results, Betfair SP, settlement |
| 06:00 | Course directory |
| 02:45 | Baseline back-test, stored with the active weight ID |
| 03:00 | Retraining |

A race first seen after its off is never recorded, and a sealed tip is never
rewritten — the same rules `TipLedger` enforced on the phone.

## API

Everything under `/v1` needs `Authorization: Bearer $RACES_API_TOKEN`.

| Route | |
|---|---|
| `GET /healthz` | Open, for Gatus |
| `GET /metrics` | Open, Prometheus text |
| `GET /v1/status` | Provider health, Betfair login class, job runs, counts |
| `GET /v1/courses` | Course directory |
| `GET /v1/racecards?day=today\|tomorrow` | Races, assessments, tips, results and match refusals for a day |
| `GET /v1/races/{id}` | One race in full, with the snapshot it was sealed on |
| `GET /v1/tips?weightsID=&date=` | Tips, with their source |
| `GET /v1/record?weightsID=&commission=` | The selected weight set's accuracy report, shared favourite benchmark, and Wilson intervals. Defaults to the active set |
| `GET /v1/model` | Active weights, every stored set, factor copy, training progress |
| `POST /v1/import` | A phone's pre-server documents. Idempotent |
| `POST /v1/backtests` | `{"weightsID": …}` or `{"weights": {…}}`, optional `from`/`to` dates and named `variants` |
| `GET /v1/backtests[/{id}]` | Stored back-tests |
| `POST /v1/admin/weights` | Install and activate a validated immutable weight set |
| `POST /v1/admin/jobs/{courses\|cards\|markets\|tips\|results\|train\|all}` | Run a job now |

```bash
T="Authorization: Bearer $RACES_API_TOKEN"
curl -s -H "$T" https://races-api.suskins.co.uk/v1/status | jq
curl -s -H "$T" -X POST -d '{"weightsID":"market-only","from":"2026-10-01"}' \
  https://races-api.suskins.co.uk/v1/backtests | jq .report
```

Every back-test report includes the exact `weightsID`, date range, shared
`corpusID`, both selection policies, the favourite arm, market log loss, and
sample counts. Sweep variants use the same race IDs and reject unknown fields.
Run the standard de-vig and value-gate sweeps with
`RACES_API_TOKEN=... bash scripts/backtest-sweeps.sh`. Set
`RACES_BACKTEST_WEIGHTS_ID`, `RACES_BACKTEST_FROM`, and `RACES_BACKTEST_TO` to
pin the weight set and date range. The output prints report ID, weight ID,
date range, sample count, and metrics for every variant.

Legacy seal-card recovery runs against the server database. After the new
server version applies its migrations, run the scan without `--apply`:

```bash
docker exec CONTAINER_NAME /races-server recover-seal-cards
```

The scan accepts a card only when all retained pre-seal versions are identical
and rerating it reproduces every stored tip field exactly. Review the payload
IDs and statuses. Back up the database, then apply only the verified rows with:

```bash
docker exec CONTAINER_NAME /races-server recover-seal-cards --apply
```

Recovery inserts missing cards only and records the source payload ID and
capture time. It never changes an existing seal card. The command uses
`RACES_DB_PATH`, which defaults to `/data/races.db` in the container.

The nightly baseline replay runs at 02:45 London time, after the final results
pass and before training. Its report ID and weight ID appear in the job summary
at `GET /v1/status`.

Manual weights require every field. The server validates the full set, mints a
new ID, stores origin `manual`, and activates it in one transaction. A stored ID
never changes.

The Record tab selects the active weight set by default. It can show earlier
sets as separate populations. The all-tip model report remains distinct from
the model and favourite subset with matching benchmark coverage.

## The contract with the app

The app decodes responses with RacesKit's own models, so the JSON here is
Swift's synthesised Codable shape: camelCase keys, optionals omitted, dates as
whole-second UTC ISO-8601 (`domain.Instant` — Swift's `.iso8601` rejects a
fractional second), enums with associated values as `{"won":{"betfairSP":4.2}}`
and `{"finished":{"_0":3}}`, `ClosedRange` as `[lower, upper]`.

Two sets of fixtures hold the two sides together, and both are compared byte
for byte by the Go tests:

- `server-*.json` — real API responses, decoded by RacesKit's
  `ServerContractTests`. Regenerate with `go test ./internal/api -update`.
- `server-golden-rating.json` — the Go rater's output on the racecard fixture,
  asserted by RacesKit's `ServerParityTests`. Regenerate with
  `go test ./internal/parity -update`.

Regenerating either means running `swift test --package-path ios/RacesKit`
before merging.

## Running it

```bash
go test ./...                 # everything, in seconds
go run ./cmd/races-server     # with the environment above
docker build -t races-server server/
```

## Backups

None yet, by choice. `races.db` is the only copy of history that cannot be
re-fetched (the free results endpoint is today-only). `store.Backup` does an
online `VACUUM INTO`; the homelab's `wedding-db-backup` task is the pattern to
copy when this changes.
