package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
)

type fakeRacecardReader struct{ err error }

func (f fakeRacecardReader) Races(context.Context, string) ([]domain.Race, error) {
	return []domain.Race{{ID: "race"}}, f.err
}
func (f fakeRacecardReader) FetchedAt(context.Context, string) (time.Time, bool) {
	return time.Time{}, false
}
func (f fakeRacecardReader) Assessments(context.Context, string) (map[string]rating.Assessment, error) {
	return map[string]rating.Assessment{}, nil
}
func (f fakeRacecardReader) RacecardTips(context.Context, string) ([]tracking.Tip, error) {
	return []tracking.Tip{{RaceID: "race"}}, nil
}
func (f fakeRacecardReader) Results(context.Context, string) ([]domain.RaceResult, error) {
	return []domain.RaceResult{{ID: "race"}}, nil
}
func (f fakeRacecardReader) Refusals(context.Context, []string) (map[string][]byte, error) {
	return map[string][]byte{"race": []byte(`{"reason":"ambiguous"}`)}, nil
}
func (f fakeRacecardReader) ArchivedRaces(context.Context) int { return 3 }

func TestBuildRacecardCollectsStoredRaceData(t *testing.T) {
	now := time.Date(2026, 9, 20, 9, 0, 0, 0, time.UTC)
	card, err := BuildRacecard(context.Background(), fakeRacecardReader{}, domain.Today, now)
	if err != nil {
		t.Fatal(err)
	}
	if card.Date != "2026-09-20" || len(card.Races) != 1 || card.Tips["race"].RaceID != "race" || card.Results["race"].ID != "race" || string(card.Refusals["race"]) != `{"reason":"ambiguous"}` || card.ArchivedRaces != 3 {
		t.Fatalf("unexpected card: %+v", card)
	}
}

func TestBuildRacecardReturnsRaceReadFailure(t *testing.T) {
	expected := errors.New("unavailable")
	_, err := BuildRacecard(context.Background(), fakeRacecardReader{err: expected}, domain.Today, time.Now())
	if !errors.Is(err, expected) {
		t.Fatalf("got %v", err)
	}
}
