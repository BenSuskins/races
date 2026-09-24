package store

import (
	"context"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
)

func open(t *testing.T) *Store {
	t.Helper()
	s, err := Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestTrainingWinner(t *testing.T) {
	s := open(t)
	ctx := context.Background()
	snap := rating.TrainingSnapshot{RaceID: "r1", CreatedAt: domain.At(time.Now()), RunnerIDs: []string{"a", "b"}, MarketProbabilities: []float64{0.5, 0.5}, FactorIDs: []rating.FactorID{}, ZScores: [][]float64{}}
	if err := s.SaveTrainingSnapshot(ctx, snap, "server"); err != nil {
		t.Fatal(err)
	}
	if ok, err := s.SetTrainingWinner(ctx, "r1", "z"); ok || err != nil {
		t.Fatal("a winner outside the field is refused", err)
	}
	if ok, err := s.SetTrainingWinner(ctx, "r1", "a"); !ok || err != nil {
		t.Fatal(ok, err)
	}
	if ok, _ := s.SetTrainingWinner(ctx, "r1", "b"); ok {
		t.Fatal("once only")
	}
	settled, _ := s.SettledTrainingSamples(ctx, time.Time{}, time.Time{})
	if len(settled) != 1 || settled[0].WinnerID != "a" {
		t.Fatal(settled)
	}
}
