package tracking

import (
	"encoding/json"
	"testing"
)

func TestOutcomeRestorationRejectsInvalidVariantsWithoutChangingValue(t *testing.T) {
	for _, input := range []string{`{"unknown":{}}`, `{"won":[]}`, `{"won":null}`} {
		t.Run(input, func(t *testing.T) {
			outcome := Outcome{Kind: Won}
			if err := json.Unmarshal([]byte(input), &outcome); err == nil {
				t.Fatalf("accepted invalid outcome %s", input)
			}
			if outcome.Kind != Won {
				t.Fatalf("failed restoration changed original outcome: %+v", outcome)
			}
		})
	}
}

func TestLedgerRestorationKeepsLegacyMissingRaceIDAndRejectsMismatchedKeys(t *testing.T) {
	var ledger Ledger
	if err := json.Unmarshal([]byte(`{"storage":{"race":{"raceID":""}}}`), &ledger); err != nil {
		t.Fatalf("legacy missing race ID: %v", err)
	}
	if _, ok := ledger.TipsByRaceID()["race"]; !ok {
		t.Fatal("lost legacy entry")
	}
	if err := json.Unmarshal([]byte(`{"storage":{"race":{"raceID":"other"}}}`), &ledger); err == nil {
		t.Fatal("accepted race ID that differs from its ledger key")
	}
	if _, ok := ledger.TipsByRaceID()["race"]; !ok {
		t.Fatal("failed restoration changed existing ledger")
	}
}

func TestLedgerRestorationPreservesNullStorage(t *testing.T) {
	var ledger Ledger
	if err := json.Unmarshal([]byte(`{"storage":null}`), &ledger); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(ledger)
	if err != nil || string(encoded) != `{"storage":null}` {
		t.Fatalf("null storage changed: %s, %v", encoded, err)
	}
}
