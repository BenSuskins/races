package service

import (
	"context"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
)

type racecardStore struct{ service *Service }

func (r racecardStore) Races(ctx context.Context, date string) ([]domain.Race, error) {
	return r.service.ports.Cards.RacesOn(ctx, date)
}
func (r racecardStore) FetchedAt(ctx context.Context, date string) (time.Time, bool) {
	return r.service.ports.Cards.RacecardsFetchedAt(ctx, date)
}
func (r racecardStore) Assessments(ctx context.Context, date string) (map[string]rating.Assessment, error) {
	return r.service.ports.Assessments.AssessmentsOn(ctx, date)
}
func (r racecardStore) RacecardTips(ctx context.Context, date string) ([]tracking.Tip, error) {
	rows, err := r.service.ports.Tips.Tips(ctx, "", date)
	if err != nil {
		return nil, err
	}
	tips := make([]tracking.Tip, len(rows))
	for i, row := range rows {
		tips[i] = row.Tip
	}
	return tips, nil
}
func (r racecardStore) Results(ctx context.Context, date string) ([]domain.RaceResult, error) {
	return r.service.ports.Results.ResultsOn(ctx, date)
}
func (r racecardStore) Refusals(ctx context.Context, ids []string) (map[string][]byte, error) {
	matches, err := r.service.ports.Markets.Matches(ctx, ids)
	if err != nil {
		return nil, err
	}
	refusals := make(map[string][]byte, len(matches))
	for id, match := range matches {
		refusals[id] = match.Refusal
	}
	return refusals, nil
}
func (r racecardStore) ArchivedRaces(ctx context.Context) int {
	return r.service.ArchivedRaceCount(ctx)
}

func (s *Service) Racecard(ctx context.Context, day domain.RaceDay) (Racecard, error) {
	return BuildRacecard(ctx, racecardStore{service: s}, day, s.Now())
}
