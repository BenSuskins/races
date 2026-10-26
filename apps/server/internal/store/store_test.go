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

func TestDisplaySnapshotsKeepFirstAndLatestPricesForMovement(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	firstAt := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	first := domain.MarketSnapshot{Source: domain.SourceLiveExchange, CapturedAt: domain.At(firstAt), Prices: map[string]domain.RunnerPrice{"horse": {BackPrice: floatPointer(3), IsActive: true}}}
	if err := s.SaveSnapshot(ctx, "race", "display", first); err != nil {
		t.Fatal(err)
	}
	latest := first
	latest.CapturedAt = domain.At(firstAt.Add(10 * time.Minute))
	latest.Prices = map[string]domain.RunnerPrice{"horse": {BackPrice: floatPointer(2), IsActive: true}}
	latest.FirstObservedAt = &first.CapturedAt
	latest.FirstObservedPrices = first.Prices
	if err := s.SaveSnapshot(ctx, "race", "display", latest); err != nil {
		t.Fatal(err)
	}
	opening, err := s.LatestSnapshot(ctx, "race", "display-opening")
	if err != nil || opening == nil || opening.CapturedAt.Time != firstAt || *opening.Prices["horse"].BackPrice != 3 {
		t.Fatalf("first observed prices changed: %+v, %v", opening, err)
	}
	display, err := s.LatestSnapshot(ctx, "race", "display")
	if err != nil || display == nil || display.CapturedAt.Time != firstAt.Add(10*time.Minute) || *display.FirstObservedPrices["horse"].BackPrice != 3 {
		t.Fatalf("latest display snapshot lost its movement base: %+v, %v", display, err)
	}
}

func floatPointer(value float64) *float64 { return &value }

func TestSaveRecoveredSealCardIsInsertOnlyAndAudited(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	capturedAt := time.Date(2026, 9, 20, 12, 0, 0, 0, time.UTC)
	recoveredAt := capturedAt.Add(24 * time.Hour)
	if err := s.SavePayload(ctx, "racingapi", "GET", "/v1/racecards/free", "day=today", 200, []byte(`{"racecards":[]}`), capturedAt); err != nil {
		t.Fatal(err)
	}
	race := domain.Race{ID: "race", Name: "Original card", Runners: []domain.Runner{{ID: "horse", Name: "Runner"}}}
	inserted, err := s.SaveRecoveredSealCard(ctx, race, 1, capturedAt, recoveredAt)
	if err != nil || !inserted {
		t.Fatalf("first recovered card was not inserted: %v, %v", inserted, err)
	}
	changed := race
	changed.Name = "Changed card"
	inserted, err = s.SaveRecoveredSealCard(ctx, changed, 1, capturedAt.Add(time.Hour), recoveredAt.Add(time.Hour))
	if err != nil || inserted {
		t.Fatalf("recovery overwrote an existing card: %v, %v", inserted, err)
	}
	got, err := s.SealCard(ctx, race.ID)
	if err != nil || got == nil || got.Name != race.Name {
		t.Fatalf("stored card changed: %+v, %v", got, err)
	}
	var payloadID int64
	var sourceFetchedAt, recordedAt string
	if err := s.db.QueryRowContext(ctx, `SELECT source_payload_id, source_fetched_at, recovered_at FROM seal_card_recoveries WHERE race_id = ?`, race.ID).Scan(&payloadID, &sourceFetchedAt, &recordedAt); err != nil {
		t.Fatal(err)
	}
	if payloadID != 1 || sourceFetchedAt != ts(capturedAt) || recordedAt != ts(recoveredAt) {
		t.Fatalf("recovery provenance changed: payload=%d fetched=%s recovered=%s", payloadID, sourceFetchedAt, recordedAt)
	}
}

func TestResultFactsRespectKnownTime(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	firstKnown := time.Date(2026, 9, 20, 12, 0, 0, 0, time.UTC)
	secondKnown := firstKnown.Add(24 * time.Hour)
	jockey := "jockey"
	trainer := "trainer"
	first := domain.RaceResult{ID: "prior-race", Date: "2026-09-20", Surface: domain.SurfaceTurf, Going: domain.GoingGoodToSoft, Type: domain.RaceTypeFlat, Finishers: []domain.Finisher{{HorseID: "first-version", Position: domain.Finished(2), JockeyID: &jockey, TrainerID: &trainer}}}
	second := domain.RaceResult{ID: "prior-race", Date: "2026-09-20", Surface: domain.SurfaceTurf, Going: domain.GoingGoodToSoft, Type: domain.RaceTypeFlat, Finishers: []domain.Finisher{{HorseID: "second-version", Position: domain.Finished(1), JockeyID: &jockey, TrainerID: &trainer}, {HorseID: "extra", Position: domain.Finished(2)}}}
	future := domain.RaceResult{ID: "future-race", Date: "2026-09-21", Surface: domain.SurfaceAllWeather, Going: domain.GoingStandardToFast, Type: domain.RaceTypeHurdle, Finishers: []domain.Finisher{{HorseID: "future-winner", Position: domain.Finished(1), JockeyID: &jockey, TrainerID: &trainer}}}
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
	if rate, _ := archive.JockeySurfaceStrikeRate(jockey, domain.SurfaceTurf); rate.Runs != 1 || rate.Wins != 0 {
		t.Fatalf("future win changed the earlier surface rate: %+v", rate)
	}
	if rate, _ := archive.JockeyRaceTypeStrikeRate(jockey, domain.RaceTypeFlat); rate.Runs != 1 || rate.Wins != 0 {
		t.Fatalf("future win changed the earlier race-type rate: %+v", rate)
	}
	if rate, _ := archive.JockeyGoingStrikeRate(jockey, domain.SurfaceTurf, domain.GoingBucketGood); rate.Runs != 1 || rate.Wins != 0 {
		t.Fatalf("future win changed the earlier going rate: %+v", rate)
	}
	if rate, _ := archive.JockeyRecentStrikeRate(jockey); rate.Runs != 1 || rate.Wins != 0 {
		t.Fatalf("future win changed the earlier recent jockey rate: %+v", rate)
	}
	if rate, _ := archive.TrainerRecentStrikeRate(trainer); rate.Runs != 1 || rate.Wins != 0 {
		t.Fatalf("future win changed the earlier recent trainer rate: %+v", rate)
	}
	if rate, _ := archive.JockeyTrainerStrikeRate(jockey, trainer); rate.Runs != 1 || rate.Wins != 0 {
		t.Fatalf("future win changed the earlier interaction rate: %+v", rate)
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
	if rate, _ := laterArchive.JockeyRecentStrikeRate(jockey); rate.Runs != 2 || rate.Wins != 2 {
		t.Fatalf("later facts were not available to the recent jockey rate: %+v", rate)
	}
	if rate, _ := laterArchive.TrainerRecentStrikeRate(trainer); rate.Runs != 2 || rate.Wins != 2 {
		t.Fatalf("later facts were not available to the recent trainer rate: %+v", rate)
	}
	if rate, _ := laterArchive.JockeyTrainerStrikeRate(jockey, trainer); rate.Runs != 2 || rate.Wins != 2 {
		t.Fatalf("later facts were not available to the interaction rate: %+v", rate)
	}
	if rate, _ := laterArchive.JockeySurfaceStrikeRate(jockey, domain.SurfaceTurf); rate.Runs != 1 || rate.Wins != 1 {
		t.Fatalf("updated surface fact was not available after collection: %+v", rate)
	}
	if rate, _ := laterArchive.JockeySurfaceStrikeRate(jockey, domain.SurfaceAllWeather); rate.Runs != 1 || rate.Wins != 1 {
		t.Fatalf("later all-weather fact was not available after collection: %+v", rate)
	}
	if rate, _ := laterArchive.JockeyRaceTypeStrikeRate(jockey, domain.RaceTypeFlat); rate.Runs != 1 || rate.Wins != 1 {
		t.Fatalf("updated race-type fact was not available after collection: %+v", rate)
	}
	if rate, _ := laterArchive.JockeyRaceTypeStrikeRate(jockey, domain.RaceTypeHurdle); rate.Runs != 1 || rate.Wins != 1 {
		t.Fatalf("later hurdle fact was not available after collection: %+v", rate)
	}
	if rate, _ := laterArchive.JockeyGoingStrikeRate(jockey, domain.SurfaceAllWeather, domain.GoingBucketFast); rate.Runs != 1 || rate.Wins != 1 {
		t.Fatalf("later going fact was not available after collection: %+v", rate)
	}
}
