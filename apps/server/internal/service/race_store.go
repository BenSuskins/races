package service

import (
	"context"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
)

type raceStore struct{ service *Service }

func (r raceStore) Race(ctx context.Context, id string) (*domain.Race, error) {
	return r.service.ports.Cards.Race(ctx, id)
}
func (r raceStore) Assessment(ctx context.Context, id string) (*rating.Assessment, error) {
	return r.service.ports.Assessments.Assessment(ctx, id)
}
func (r raceStore) Tip(ctx context.Context, id string) (*tracking.Tip, error) {
	row, err := r.service.ports.Tips.Tip(ctx, id)
	if row == nil || err != nil {
		return nil, err
	}
	return &row.Tip, nil
}
func (r raceStore) Result(ctx context.Context, id string) (*domain.RaceResult, error) {
	return r.service.ports.Results.Result(ctx, id)
}
func (r raceStore) Snapshot(ctx context.Context, id, kind string) (*domain.MarketSnapshot, error) {
	return r.service.ports.Markets.LatestSnapshot(ctx, id, kind)
}
func (r raceStore) Refusal(ctx context.Context, id string) ([]byte, error) {
	matches, err := r.service.ports.Markets.Matches(ctx, []string{id})
	if err != nil {
		return nil, err
	}
	return matches[id].Refusal, nil
}
func (s *Service) RaceDetail(ctx context.Context, id string) (*RaceDetail, error) {
	return ReadRace(ctx, raceStore{service: s}, id)
}
