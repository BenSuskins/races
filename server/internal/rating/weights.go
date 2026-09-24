package rating

// Weights is every tunable number in the model. The JSON is Swift's
// RatingWeights, so presets, trained sets and device uploads interchange.
//
// ID is stamped onto every tip. Change the numbers, change the id — otherwise
// tuning silently invalidates the accuracy history.
type Weights struct {
	ID                      string             `json:"id"`
	MarketExponent          float64            `json:"marketExponent"`
	FormInfluence           float64            `json:"formInfluence"`
	FormInfluenceNoMarket   float64            `json:"formInfluenceNoMarket"`
	Clip                    float64            `json:"clip"`
	OverroundMethod         OverroundMethod    `json:"overroundMethod"`
	MinimumMarketCoverage   float64            `json:"minimumMarketCoverage"`
	FactorWeights           map[string]float64 `json:"factorWeights"`
	FormDecay               float64            `json:"formDecay"`
	FormPoints              map[string]float64 `json:"formPoints"`
	FormSeasonBreakPenalty  float64            `json:"formSeasonBreakPenalty"`
	FormLongBreakPenalty    float64            `json:"formLongBreakPenalty"`
	FormMaxRuns             int                `json:"formMaxRuns"`
	MinimumStrikeRateSample int                `json:"minimumStrikeRateSample"`
	MinimumValueEdge        float64            `json:"minimumValueEdge"`
	MinimumValueProbability float64            `json:"minimumValueProbability"`
}

// NewWeights applies Swift's initialiser defaults.
func NewWeights(id string, factorWeights map[string]float64) Weights {
	return Weights{
		ID: id, MarketExponent: 1.0, FormInfluence: 0.35, FormInfluenceNoMarket: 0.90,
		Clip: 2.5, OverroundMethod: Proportional, MinimumMarketCoverage: 0.80,
		FactorWeights: factorWeights, FormDecay: 0.75, FormPoints: DefaultFormPoints(),
		FormSeasonBreakPenalty: 0.80, FormLongBreakPenalty: 0.50, FormMaxRuns: 6,
		MinimumStrikeRateSample: 30, MinimumValueEdge: 0.05, MinimumValueProbability: 0.08,
	}
}

func (w Weights) Weight(id FactorID) float64 { return w.FactorWeights[string(id)] }

func (w Weights) Scorer() FormScorer {
	return FormScorer{Points: w.FormPoints, Decay: w.FormDecay, SeasonBreakPenalty: w.FormSeasonBreakPenalty, LongBreakPenalty: w.FormLongBreakPenalty, MaxRuns: w.FormMaxRuns}
}

// Clone deep-copies the maps so a trained candidate cannot mutate a preset.
func (w Weights) Clone() Weights {
	c := w
	c.FactorWeights = make(map[string]float64, len(w.FactorWeights))
	for k, v := range w.FactorWeights {
		c.FactorWeights[k] = v
	}
	c.FormPoints = make(map[string]float64, len(w.FormPoints))
	for k, v := range w.FormPoints {
		c.FormPoints[k] = v
	}
	return c
}

func baseFactorWeights() map[string]float64 {
	return map[string]float64{
		string(OfficialRating): 0.30, string(HandicapBandPosition): 0.20, string(RecentForm): 0.25,
		string(WonLastTime): 0.10, string(CompletionRate): 0.08, string(DaysSinceLastRun): 0.06,
		string(Age): 0.04, string(WeightCarried): 0.02, string(Draw): 0.00, string(Headgear): 0.00,
		string(JockeyStrikeRate): 0.00, string(TrainerStrikeRate): 0.00,
	}
}

// V1 is the original market-anchored configuration, kept for comparison.
func V1() Weights {
	w := NewWeights("v1", baseFactorWeights())
	w.MinimumValueEdge, w.MinimumValueProbability = 0, 0
	return w
}

// V2 is the current configuration: v1's probabilities with a value-aware
// selection layer.
func V2() Weights { return NewWeights("v2", baseFactorWeights()) }

// MarketOnly is the control arm: the market, unmodified.
func MarketOnly() Weights {
	w := NewWeights("market-only", map[string]float64{})
	w.FormInfluence, w.FormInfluenceNoMarket = 0, 0
	return w
}

// Presets are the weight sets the server always knows.
func Presets() []Weights { return []Weights{V1(), V2(), MarketOnly()} }
