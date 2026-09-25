package backtest

import (
	"encoding/json"
	"testing"

	"github.com/bensuskins/races/server/internal/rating"
)

func TestApplyOverridesClonesAndRejectsUnknownFields(t *testing.T) {
	base := rating.V3()
	variant := SweepVariant{Name: "low-decay", Overrides: map[string]json.RawMessage{
		"formDecay":       json.RawMessage("0.4"),
		"overroundMethod": json.RawMessage(`"power"`),
	}}
	got, err := ApplyOverrides(base, variant)
	if err != nil || got.FormDecay != 0.4 || got.OverroundMethod != rating.Power || got.ID != base.ID {
		t.Fatalf("override failed: %+v, %v", got, err)
	}
	if base.FormDecay == got.FormDecay || base.MinimumValueProbability != 1 {
		t.Fatal("sweep mutated the base set")
	}
	if _, err := ApplyOverrides(base, SweepVariant{Name: "bad", Overrides: map[string]json.RawMessage{"newThreshold": json.RawMessage("0.5")}}); err == nil {
		t.Fatal("unknown field was accepted")
	}
}
