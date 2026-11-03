package service

import (
	"context"

	"github.com/bensuskins/races/server/internal/domain"
)

type Monitoring struct {
	Counts          domain.Counts
	Jobs            []domain.JobRun
	ActiveWeightsID string
}

func (s *Service) Monitoring(ctx context.Context) Monitoring {
	status := Monitoring{Counts: s.ports.Jobs.Counts(ctx)}
	status.Jobs, _ = s.ports.Jobs.JobRuns(ctx)
	if active, _ := s.ports.Weights.ActiveWeights(ctx); active != nil {
		status.ActiveWeightsID = active.ID
	}
	return status
}

func (s *Service) CheckDatabase(ctx context.Context) error {
	_, err := s.ports.Weights.ActiveWeights(ctx)
	return err
}
