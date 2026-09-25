-- The complete card the rater used when it sealed a tip.
CREATE TABLE seal_cards (
    race_id      TEXT PRIMARY KEY,
    version      INTEGER NOT NULL,
    captured_at  TEXT NOT NULL,
    json         TEXT NOT NULL
);
