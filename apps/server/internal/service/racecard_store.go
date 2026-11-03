package service

import (
	"context"
	"github.com/bensuskins/races/server/internal/domain"
)

type racecardStore struct {
	cardsPort
	assessmentsPort
	tipsPort
	resultsPort
	marketsPort
	archivedRaces func(context.Context) int
}

func (reader racecardStore) ArchivedRaces(ctx context.Context) int { return reader.archivedRaces(ctx) }
func (s *Service) Racecard(ctx context.Context, day domain.RaceDay) (Racecard, error) {
	reader := racecardStore{s.ports.Cards, s.ports.Assessments, s.ports.Tips, s.ports.Results, s.ports.Markets, s.ArchivedRaceCount}
	return BuildRacecard(ctx, reader, day, s.Now())
}
