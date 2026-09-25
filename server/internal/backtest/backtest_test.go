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
