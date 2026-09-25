package store

import (
	"context"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
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

func TestSealCardIsImmutableAndStoredWithTip(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	sealedRace := domain.Race{ID: "race", Name: "Original card", Runners: []domain.Runner{{ID: "horse", Name: "Runner"}}}
	tip := tracking.Tip{RaceID: sealedRace.ID}
	sealedAt := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	if err := s.SaveSealedTip(ctx, tip, sealedRace, "server", sealedAt); err != nil {
		t.Fatal(err)
	}
	changedRace := sealedRace
	changedRace.Name = "Updated card"
	if err := s.SaveRaces(ctx, []domain.Race{changedRace}, sealedAt.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveSealedTip(ctx, tracking.Tip{RaceID: sealedRace.ID, WeightsID: "new"}, changedRace, "server", sealedAt.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	got, err := s.SealCard(ctx, sealedRace.ID)
	if err != nil || got == nil || got.Name != sealedRace.Name || len(got.Runners) != 1 {
		t.Fatalf("seal card changed: %+v, %v", got, err)
	}
}

func TestResultFactsRespectKnownTime(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	firstKnown := time.Date(2026, 9, 20, 12, 0, 0, 0, time.UTC)
	secondKnown := firstKnown.Add(24 * time.Hour)
	jockey := "jockey"
	first := domain.RaceResult{ID: "prior-race", Date: "2026-09-20", Finishers: []domain.Finisher{{HorseID: "first-version", Position: domain.Finished(2), JockeyID: &jockey}}}
	second := domain.RaceResult{ID: "prior-race", Date: "2026-09-20", Finishers: []domain.Finisher{{HorseID: "second-version", Position: domain.Finished(1), JockeyID: &jockey}, {HorseID: "extra", Position: domain.Finished(2)}}}
	future := domain.RaceResult{ID: "future-race", Date: "2026-09-21", Finishers: []domain.Finisher{{HorseID: "future-winner", Position: domain.Finished(1), JockeyID: &jockey}}}
	if _, err := s.SaveResults(ctx, []domain.RaceResult{first}, firstKnown); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SaveResults(ctx, []domain.RaceResult{second, future}, secondKnown); err != nil {
		t.Fatal(err)
	}
	before, err := s.ResultFactsKnownBefore(ctx, firstKnown.Add(time.Hour))
	if err != nil || len(before) != 1 || before[0].Finishers[0].HorseID != "first-version" {
		t.Fatalf("as-of query returned later fact: %+v, %v", before, err)
	}
	archive := tracking.NewArchive()
	for _, result := range before {
		archive.Ingest(result)
	}
	if rate, _ := archive.JockeyStrikeRate(jockey); rate.Runs != 1 || rate.Wins != 0 {
		t.Fatalf("future win changed the earlier jockey rate: %+v", rate)
	}
	after, err := s.ResultFactsKnownBefore(ctx, secondKnown.Add(time.Second))
	latestPrior := ""
	for _, result := range after {
		if result.ID == "prior-race" && len(result.Finishers) > 0 {
			latestPrior = result.Finishers[0].HorseID
		}
	}
	if err != nil || len(after) != 2 || latestPrior != "second-version" {
		t.Fatalf("query did not return latest known fact: %+v, %v", after, err)
	}
	laterArchive := tracking.NewArchive()
	for _, result := range after {
		laterArchive.Ingest(result)
	}
	if rate, _ := laterArchive.JockeyStrikeRate(jockey); rate.Runs != 2 || rate.Wins != 2 {
		t.Fatalf("newer facts were not available after collection: %+v", rate)
	}
}
