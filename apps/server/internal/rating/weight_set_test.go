package rating

import "testing"

func TestManualWeightSetCopiesItsInputsAndSnapshots(t *testing.T) {
	weights := V3()
	set, err := NewManualWeightSet(weights, "manual-1")
	if err != nil {
		t.Fatal(err)
	}
	weights.FactorWeights[string(OfficialRating)] = 0.99
	weights.FormPoints["1"] = 0.99
	snapshot := set.Snapshot()
	expected := V3()
	if snapshot.ID != "manual-1" || snapshot.FactorWeights[string(OfficialRating)] != expected.FactorWeights[string(OfficialRating)] || snapshot.FormPoints["1"] != expected.FormPoints["1"] {
		t.Fatal("weight set shares its input")
	}
	snapshot.FactorWeights[string(OfficialRating)] = 0.88
	if set.Snapshot().FactorWeights[string(OfficialRating)] != expected.FactorWeights[string(OfficialRating)] {
		t.Fatal("weight set shares its snapshot")
	}
}

func TestManualWeightSetRejectsInvalidState(t *testing.T) {
	weights := V3()
	if _, err := NewManualWeightSet(weights, ""); err == nil {
		t.Fatal("accepted an empty ID")
	}
	weights.FormInfluence = -1
	if _, err := NewManualWeightSet(weights, "manual-1"); err == nil {
		t.Fatal("accepted invalid weights")
	}
}
