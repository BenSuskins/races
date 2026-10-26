-- Append-only copies preserve when each result became available to the model.
CREATE TABLE result_facts (
    id         INTEGER PRIMARY KEY,
    race_id    TEXT NOT NULL,
    known_at   TEXT NOT NULL,
    json       TEXT NOT NULL,
    UNIQUE (race_id, known_at)
);
CREATE INDEX result_facts_known ON result_facts (known_at, race_id);

INSERT OR IGNORE INTO result_facts (race_id, known_at, json)
SELECT race_id, fetched_at, json FROM results;
