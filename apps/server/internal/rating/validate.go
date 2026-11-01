package rating

import (
	"errors"
	"fmt"
	"math"
)

func ValidateManualWeights(weights Weights) error {
	finite := func(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }
	if weights.OverroundMethod != Proportional && weights.OverroundMethod != Power {
		return errors.New("invalid overroundMethod")
	}
	if !finite(weights.MarketExponent) || weights.MarketExponent <= 0 || weights.MarketExponent > 4 ||
		!finite(weights.FormInfluence) || weights.FormInfluence < 0 || weights.FormInfluence > 1 ||
		!finite(weights.FormInfluenceNoMarket) || weights.FormInfluenceNoMarket < 0 || weights.FormInfluenceNoMarket > 1 ||
		!finite(weights.Clip) || weights.Clip <= 0 || weights.Clip > 10 ||
		!finite(weights.MinimumMarketCoverage) || weights.MinimumMarketCoverage < 0 || weights.MinimumMarketCoverage > 1 ||
		!finite(weights.FormDecay) || weights.FormDecay < 0 || weights.FormDecay > 1 ||
		!finite(weights.FormSeasonBreakPenalty) || weights.FormSeasonBreakPenalty < 0 || weights.FormSeasonBreakPenalty > 1 ||
		!finite(weights.FormLongBreakPenalty) || weights.FormLongBreakPenalty < 0 || weights.FormLongBreakPenalty > 1 ||
		weights.FormMaxRuns < 1 || weights.FormMaxRuns > 20 || weights.MinimumStrikeRateSample < 30 ||
		!finite(weights.MinimumValueEdge) || weights.MinimumValueEdge < -1 || weights.MinimumValueEdge > 10 ||
		!finite(weights.MinimumValueProbability) || weights.MinimumValueProbability < 0 || weights.MinimumValueProbability > 1 {
		return errors.New("weight fields are outside valid ranges")
	}
	if len(weights.FactorWeights) != len(AllFactors) || len(weights.FormPoints) != len(DefaultFormPoints()) {
		return errors.New("factorWeights and formPoints must contain every supported key")
	}
	for _, id := range AllFactors {
		value, ok := weights.FactorWeights[string(id)]
		if !ok || !finite(value) || value < 0 || value > 1 {
			return fmt.Errorf("invalid factor weight %q", id)
		}
	}
	for key := range DefaultFormPoints() {
		value, ok := weights.FormPoints[key]
		if !ok || !finite(value) || value < 0 || value > 1 {
			return fmt.Errorf("invalid form point %q", key)
		}
	}
	return nil
}
