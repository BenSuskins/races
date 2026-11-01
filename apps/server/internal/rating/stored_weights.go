package rating

import "github.com/bensuskins/races/server/internal/domain"

// StoredWeights identifies a weight set and its activation state.
type StoredWeights struct {
	Weights   Weights        `json:"weights"`
	Origin    string         `json:"origin"`
	CreatedAt domain.Instant `json:"createdAt"`
	Active    bool           `json:"active"`
}
