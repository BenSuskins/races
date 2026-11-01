package service

import (
	"context"
	"crypto/rand"
	"fmt"

	"github.com/bensuskins/races/server/internal/rating"
)

// InstallWeights validates and activates a new immutable weight set.
func (s *Service) InstallWeights(ctx context.Context, weights rating.Weights) (rating.Weights, error) {
	if err := rating.ValidateManualWeights(weights); err != nil {
		return rating.Weights{}, InvalidBacktest{Message: err.Error()}
	}
	var suffix [8]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return rating.Weights{}, err
	}
	set, err := rating.NewManualWeightSet(weights, fmt.Sprintf("manual-%d-%x", s.Now().Unix(), suffix[:]))
	if err != nil {
		return rating.Weights{}, InvalidBacktest{Message: err.Error()}
	}
	weights = set.Snapshot()
	if err := s.ports.Weights.InstallManualWeights(ctx, weights, s.Now()); err != nil {
		return rating.Weights{}, err
	}
	return weights, nil
}
