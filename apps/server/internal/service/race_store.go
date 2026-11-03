package service

import "context"

type raceStore struct {
	cardsPort
	assessmentsPort
	tipsPort
	resultsPort
	marketsPort
}

func (s *Service) RaceDetail(ctx context.Context, id string) (*RaceDetail, error) {
	reader := raceStore{s.ports.Cards, s.ports.Assessments, s.ports.Tips, s.ports.Results, s.ports.Markets}
	return ReadRace(ctx, reader, id)
}
