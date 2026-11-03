package service

import (
	"context"
	"errors"

	"github.com/bensuskins/races/server/internal/rating"
)

type FactorView struct {
	ID        rating.FactorID `json:"id"`
	Label     string          `json:"label"`
	Summary   string          `json:"summary"`
	Rationale string          `json:"rationale,omitempty"`
}

type Model struct {
	ModelVersion  string                 `json:"modelVersion"`
	Active        rating.Weights         `json:"active"`
	Weights       []rating.StoredWeights `json:"weights"`
	Factors       []FactorView           `json:"factors"`
	Training      any                    `json:"training,omitempty"`
	Samples       map[string]int         `json:"samples"`
	ArchivedRaces int                    `json:"archivedRaces"`
}

func (s *Service) Model(ctx context.Context) (Model, error) {
	active, err := s.ports.Weights.ActiveWeights(ctx)
	if err != nil || active == nil {
		return Model{}, errors.Join(err, errors.New("no active weights"))
	}
	all, _ := s.ports.Weights.AllWeights(ctx)
	model := Model{ModelVersion: rating.ModelVersion, Active: *active, Weights: all}
	for _, id := range rating.AllFactors {
		model.Factors = append(model.Factors, FactorView{ID: id, Label: id.Label(), Summary: id.Summary(), Rationale: id.Rationale()})
	}
	if report := s.LastTrainingReport(ctx); report != nil {
		model.Training = report
	}
	settled, pending := s.ports.Training.TrainingCounts(ctx)
	model.Samples = map[string]int{"settled": settled, "pending": pending, "minimumRaces": s.Training.MinimumRaces}
	model.ArchivedRaces = s.ArchivedRaceCount(ctx)
	return model, nil
}
