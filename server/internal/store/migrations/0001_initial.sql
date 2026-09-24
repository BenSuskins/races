-- The server's whole history. Key columns are indexed; full domain objects are
-- kept as JSON in the shape the app already decodes, so the schema does not
-- have to chase every field a provider adds.

-- Every provider response, gzipped. The free results endpoint is today-only,
-- so this is the only copy of a day's raw data, and it holds fields we do not
-- parse yet — which is what a future model will want.
CREATE TABLE raw_payloads (
    id          INTEGER PRIMARY KEY,
    provider    TEXT    NOT NULL,
    method      TEXT    NOT NULL,
    path        TEXT    NOT NULL,
    query       TEXT    NOT NULL DEFAULT '',
    status      INTEGER NOT NULL,
    fetched_at  TEXT    NOT NULL,
    body        BLOB    NOT NULL
);
CREATE INDEX raw_payloads_fetched ON raw_payloads (provider, path, fetched_at);

CREATE TABLE courses (
    id          TEXT PRIMARY KEY,
    updated_at  TEXT NOT NULL,
    json        TEXT NOT NULL
);

-- The latest version of each race's card. A race is re-fetched through the day
-- as non-runners come out; the version that was rated at the seal is frozen on
-- the tip and in market_snapshots, not here.
CREATE TABLE races (
    id          TEXT PRIMARY KEY,
    date        TEXT NOT NULL,
    course      TEXT NOT NULL,
    off_at      TEXT,
    updated_at  TEXT NOT NULL,
    json        TEXT NOT NULL
);
CREATE INDEX races_date ON races (date);

CREATE TABLE results (
    race_id     TEXT PRIMARY KEY,
    date        TEXT NOT NULL,
    fetched_at  TEXT NOT NULL,
    json        TEXT NOT NULL
);
CREATE INDEX results_date ON results (date);

-- One row per race per matching pass outcome: either a market (with the frozen
-- horse → selection map) or a refusal with its reason.
CREATE TABLE market_matches (
    race_id         TEXT PRIMARY KEY,
    market_id       TEXT,
    matched_at      TEXT NOT NULL,
    reference_json  TEXT,
    refusal_json    TEXT
);

-- Prices as the rater saw them. `seal` is the snapshot a tip was sealed on;
-- `display` is the latest draft.
CREATE TABLE market_snapshots (
    id           INTEGER PRIMARY KEY,
    race_id      TEXT NOT NULL,
    kind         TEXT NOT NULL,
    captured_at  TEXT NOT NULL,
    json         TEXT NOT NULL
);
CREATE INDEX market_snapshots_race ON market_snapshots (race_id, kind, captured_at);

CREATE TABLE starting_prices (
    market_id     TEXT    NOT NULL,
    selection_id  INTEGER NOT NULL,
    bsp           REAL    NOT NULL,
    fetched_at    TEXT    NOT NULL,
    PRIMARY KEY (market_id, selection_id)
);

-- The latest assessment of each race, for display.
CREATE TABLE assessments (
    race_id       TEXT PRIMARY KEY,
    generated_at  TEXT NOT NULL,
    weights_id    TEXT NOT NULL,
    json          TEXT NOT NULL
);

-- The accuracy record. `source` is `server` or `device:<name>` for history
-- uploaded from a phone.
CREATE TABLE tips (
    race_id       TEXT PRIMARY KEY,
    race_date     TEXT NOT NULL,
    off_at        TEXT,
    weights_id    TEXT NOT NULL,
    sealed_at     TEXT,
    outcome_kind  TEXT,
    source        TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    json          TEXT NOT NULL
);
CREATE INDEX tips_date ON tips (race_date);
CREATE INDEX tips_weights ON tips (weights_id);

CREATE TABLE weights (
    id          TEXT PRIMARY KEY,
    origin      TEXT    NOT NULL,
    created_at  TEXT    NOT NULL,
    active      INTEGER NOT NULL DEFAULT 0,
    json        TEXT    NOT NULL
);

-- Frozen model inputs at the seal, plus the winner once the race settles.
CREATE TABLE training_samples (
    race_id     TEXT PRIMARY KEY,
    created_at  TEXT NOT NULL,
    winner_id   TEXT,
    source      TEXT NOT NULL,
    json        TEXT NOT NULL
);

-- Singleton documents: the strike-rate archive, the last training report.
CREATE TABLE documents (
    name        TEXT PRIMARY KEY,
    updated_at  TEXT NOT NULL,
    json        TEXT NOT NULL
);

CREATE TABLE backtests (
    id          INTEGER PRIMARY KEY,
    created_at  TEXT NOT NULL,
    weights_id  TEXT NOT NULL,
    request     TEXT NOT NULL,
    report      TEXT NOT NULL
);

-- Device uploads, kept whole so an import can be audited or replayed.
CREATE TABLE imports (
    id           INTEGER PRIMARY KEY,
    device       TEXT NOT NULL,
    received_at  TEXT NOT NULL,
    summary      TEXT NOT NULL,
    raw          BLOB NOT NULL
);

CREATE TABLE job_runs (
    name           TEXT PRIMARY KEY,
    started_at     TEXT,
    finished_at    TEXT,
    succeeded_at   TEXT,
    error          TEXT,
    summary        TEXT
);
