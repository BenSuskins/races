package service

import (
	"context"
	"encoding/json"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
)

// Racecard combines a day's stored card and the related decisions.
type Racecard struct {
	Day           domain.RaceDay               `json:"day"`
	Date          string                       `json:"date"`
	FetchedAt     *domain.Instant              `json:"fetchedAt,omitempty"`
	Races         []domain.Race                `json:"races"`
	Assessments   map[string]rating.Assessment `json:"assessments"`
	Tips          map[string]tracking.Tip      `json:"tips"`
	Results       map[string]domain.RaceResult `json:"results"`
	Refusals      map[string]json.RawMessage   `json:"refusals"`
	ArchivedRaces int                          `json:"archivedRaces"`
}

// RacecardReader supplies the information needed to assemble a daily card.
type RacecardReader interface {
	Races(context.Context, string) ([]domain.Race, error)
	FetchedAt(context.Context, string) (time.Time, bool)
	Assessments(context.Context, string) (map[string]rating.Assessment, error)
	RacecardTips(context.Context, string) ([]tracking.Tip, error)
	Results(context.Context, string) ([]domain.RaceResult, error)
	Refusals(context.Context, []string) (map[string][]byte, error)
	ArchivedRaces(context.Context) int
}

func BuildRacecard(ctx context.Context, reader RacecardReader, day domain.RaceDay, now time.Time) (Racecard, error) {
	date := domain.DayStringFor(day, now)
	card := Racecard{Day: day, Date: date, Races: []domain.Race{}, Tips: map[string]tracking.Tip{}, Results: map[string]domain.RaceResult{}, Refusals: map[string]json.RawMessage{}}
	var err error
	if card.Races, err = reader.Races(ctx, date); err != nil {
		return Racecard{}, err
	}
	if card.Races == nil {
		card.Races = []domain.Race{}
	}
	if at, ok := reader.FetchedAt(ctx, date); ok {
		card.FetchedAt = domain.Ptr(at)
	}
	if card.Assessments, err = reader.Assessments(ctx, date); err != nil {
		return Racecard{}, err
	}
	tips, _ := reader.RacecardTips(ctx, date)
	for _, tip := range tips {
		card.Tips[tip.RaceID] = tip
	}
	results, _ := reader.Results(ctx, date)
	for _, result := range results {
		card.Results[result.ID] = result
	}
	ids := make([]string, len(card.Races))
	for i, race := range card.Races {
		ids[i] = race.ID
	}
	refusals, _ := reader.Refusals(ctx, ids)
	for id, refusal := range refusals {
		if len(refusal) > 0 {
			card.Refusals[id] = refusal
		}
	}
	card.ArchivedRaces = reader.ArchivedRaces(ctx)
	return card, nil
}
