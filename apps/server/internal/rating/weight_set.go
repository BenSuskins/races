package rating

import "errors"

// ManualWeightSet owns a validated set before it is stored and activated.
type ManualWeightSet struct{ weights Weights }

func NewManualWeightSet(weights Weights, id string) (ManualWeightSet, error) {
	if id == "" {
		return ManualWeightSet{}, errors.New("weight set needs an ID")
	}
	if err := ValidateManualWeights(weights); err != nil {
		return ManualWeightSet{}, err
	}
	weights = weights.Clone()
	weights.ID = id
	return ManualWeightSet{weights: weights}, nil
}

func (set ManualWeightSet) Snapshot() Weights { return set.weights.Clone() }
