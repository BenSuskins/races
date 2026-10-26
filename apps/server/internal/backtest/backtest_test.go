package backtest

import (
	"context"
	"encoding/json"
	"math"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/store"
)

func TestApplyOverridesClonesAndRejectsUnknownFields(t *testing.T) {
	base := rating.V3()
	formPoints := map[string]float64{
		"1": 1, "2": 0.8, "3": 0.6, "4": 0.4, "5": 0.3,
		"6": 0.2, "7": 0.15, "8": 0.1, "9": 0.08,
		"tenOrWorse": 0.04, "nonCompletion": 0,
	}
	variant := SweepVariant{Name: "low-decay", Overrides: map[string]json.RawMessage{
		"formDecay":       json.RawMessage("0.4"),
		"overroundMethod": json.RawMessage(`"power"`),
		"formPoints":      json.RawMessage(`{"1":1,"2":0.8,"3":0.6,"4":0.4,"5":0.3,"6":0.2,"7":0.15,"8":0.1,"9":0.08,"tenOrWorse":0.04,"nonCompletion":0}`),
	}}
	got, err := ApplyOverrides(base, variant)
	if err != nil || got.FormDecay != 0.4 || got.OverroundMethod != rating.Power || got.ID != base.ID || !equalPoints(got.FormPoints, formPoints) {
		t.Fatalf("override failed: %+v, %v", got, err)
	}
	if base.FormDecay == got.FormDecay || base.MinimumValueProbability != 1 || equalPoints(base.FormPoints, got.FormPoints) {
		t.Fatal("sweep mutated the base set")
	}
	if _, err := ApplyOverrides(base, SweepVariant{Name: "bad", Overrides: map[string]json.RawMessage{"newThreshold": json.RawMessage("0.5")}}); err == nil {
		t.Fatal("unknown field was accepted")
	}
}

func TestApplyOverridesRejectsInvalidFormPointCurves(t *testing.T) {
	invalid := []string{
		`{"1":1}`, // incomplete curves make named variants hard to compare
		`{"1":0.5,"2":0.8,"3":0.6,"4":0.4,"5":0.3,"6":0.2,"7":0.15,"8":0.1,"9":0.08,"tenOrWorse":0.04,"nonCompletion":0}`,
		`{"1":1,"2":0.8,"3":0.6,"4":0.4,"5":0.3,"6":0.2,"7":0.15,"8":0.1,"9":0.08,"tenOrWorse":0.04,"nonCompletion":0.01}`,
	}
	for _, raw := range invalid {
		if _, err := ApplyOverrides(rating.V3(), SweepVariant{Name: "bad-form-curve", Overrides: map[string]json.RawMessage{"formPoints": json.RawMessage(raw)}}); err == nil {
			t.Fatalf("invalid form-point curve was accepted: %s", raw)
		}
	}
}

func equalPoints(left, right map[string]float64) bool {
	if len(left) != len(right) {
		return false
	}
	for key, value := range left {
		if right[key] != value {
			return false
		}
	}
	return true
}

func TestFactorCoverageReportsAvailableJockeyTrainerValues(t *testing.T) {
	assessment := rating.Assessment{Runners: []rating.RunnerAssessment{
		{Contributions: []rating.Contribution{{Factor: rating.JockeyTrainerStrikeRate, Availability: rating.Availability{Kind: rating.Available}}}},
		{Contributions: []rating.Contribution{{Factor: rating.JockeyTrainerStrikeRate, Availability: rating.Availability{Kind: rating.MissingData}}}},
		{Contributions: []rating.Contribution{{Factor: rating.JockeyTrainerStrikeRate, Availability: rating.Availability{Kind: rating.Available}}}},
	}}
	var accumulator factorCoverageAccumulator
	accumulator.add(assessment, rating.JockeyTrainerStrikeRate)
	coverage := accumulator.report()
	if coverage.EligibleRunners != 3 || coverage.AvailableRunners != 2 || coverage.Rate == nil || math.Abs(*coverage.Rate-2.0/3.0) > 1e-12 {
		t.Fatalf("wrong factor coverage: %+v", coverage)
	}
}

func TestSnapshotLogLossDoesNotStandInForEmptyReplayCohort(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	weights := rating.V3()
	if _, err := st.EnsureWeights(ctx, weights, "preset", now); err != nil {
		t.Fatal(err)
	}
	snapshot := rating.TrainingSnapshot{
		RaceID: "training-race", CreatedAt: domain.At(now),
		RunnerIDs: []string{"horse-1", "horse-2"}, MarketProbabilities: []float64{0.5, 0.5},
		FactorIDs: []rating.FactorID{rating.RecentForm}, ZScores: [][]float64{{-2, 2}},
	}
	if err := st.SaveTrainingSnapshot(ctx, snapshot, "server"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SetTrainingWinner(ctx, snapshot.RaceID, "horse-1"); err != nil {
		t.Fatal(err)
	}
	report, err := Run(ctx, st, weights, Request{})
	if err != nil {
		t.Fatal(err)
	}
	if report.HighestProbability.Races != 0 || report.MarketLogLoss != nil {
		t.Fatalf("expected an empty replay cohort: %+v", report)
	}
	if report.SnapshotLogLoss == nil || report.SnapshotMarketLogLoss == nil {
		t.Fatalf("expected separate training-snapshot diagnostics: %+v", report)
	}
	if report.BeatsMarket != nil {
		t.Fatalf("training snapshots must not decide the replay promotion gate: %+v", report.BeatsMarket)
	}
}
