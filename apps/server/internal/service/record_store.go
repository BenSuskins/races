package service

import "context"

type recordStore struct {
	weightsPort
	tipsPort
	archivedRaces func(context.Context) int
}

func (reader recordStore) ArchivedRaces(ctx context.Context) int { return reader.archivedRaces(ctx) }

// Record returns the accuracy report for one weight population.
func (s *Service) Record(ctx context.Context, weightsID string, commission float64) (Record, error) {
	reader := recordStore{s.ports.Weights, s.ports.Tips, s.ArchivedRaceCount}
	return BuildRecord(ctx, reader, weightsID, commission)
}
