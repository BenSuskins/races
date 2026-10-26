CREATE TABLE seal_card_recoveries (
    race_id             TEXT PRIMARY KEY REFERENCES seal_cards(race_id),
    source_payload_id   INTEGER NOT NULL REFERENCES raw_payloads(id),
    source_fetched_at   TEXT NOT NULL,
    recovered_at        TEXT NOT NULL
);
