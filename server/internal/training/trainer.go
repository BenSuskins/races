// Package training re-fits the model's weights from settled races.
//
// A port of OnDeviceWeightTrainer. It ran on a phone over whatever races that
// phone happened to see; here it runs nightly over every race the server has
// sealed, which is the corpus the design always wanted and never had.
package training

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"

	"github.com/bensuskins/races/server/internal/rating"
)

// Race is a snapshot plus the winner, attached only after settlement.
type Race struct {
	Snapshot rating.TrainingSnapshot `json:"snapshot"`
	WinnerID string                  `json:"winnerID"`
}

// FloatRange is Swift's ClosedRange<Double>, which Codable writes as a pair.
type FloatRange struct{ Lower, Upper float64 }

func (r FloatRange) MarshalJSON() ([]byte, error) { return json.Marshal([2]float64{r.Lower, r.Upper}) }

func (r *FloatRange) UnmarshalJSON(data []byte) error {
	var pair []float64
	if err := json.Unmarshal(data, &pair); err != nil {
		return err
	}
	if len(pair) != 2 {
		return fmt.Errorf("range: want 2 bounds, got %d", len(pair))
	}
	r.Lower, r.Upper = pair[0], pair[1]
	return nil
}

// Configuration matches WeightTrainingConfiguration.
type Configuration struct {
	MinimumRaces        int        `json:"minimumRaces"`
	ValidationRaces     int        `json:"validationRaces"`
	TrainingWindow      int        `json:"trainingWindow"`
	Epochs              int        `json:"epochs"`
	LearningRate        float64    `json:"learningRate"`
	Regularisation      float64    `json:"regularisation"`
	MinimumImprovement  float64    `json:"minimumImprovement"`
	MarketExponentRange FloatRange `json:"marketExponentRange"`
	FormInfluenceRange  FloatRange `json:"formInfluenceRange"`
}

func DefaultConfiguration() Configuration {
	return Configuration{
		MinimumRaces: 500, ValidationRaces: 100, TrainingWindow: 2000, Epochs: 160,
		LearningRate: 0.025, Regularisation: 0.02, MinimumImprovement: 0.002,
		MarketExponentRange: FloatRange{0.5, 1.5}, FormInfluenceRange: FloatRange{0.05, 0.90},
	}
}

// Report says what a training pass did.
type Report struct {
	Trained                    bool           `json:"trained"`
	SettledRaceCount           int            `json:"settledRaceCount"`
	TrainingLogLoss            *float64       `json:"trainingLogLoss,omitempty"`
	BaselineValidationLogLoss  *float64       `json:"baselineValidationLogLoss,omitempty"`
	CandidateValidationLogLoss *float64       `json:"candidateValidationLogLoss,omitempty"`
	Promoted                   bool           `json:"promoted"`
	Weights                    rating.Weights `json:"weights"`
}

// Train fits factor weights and the market/form blend by minimising multiclass
// log loss with L2 pull toward the current weights. The newest races are held
// out, never fitted, and the candidate is promoted only if it beats the current
// weights on them.
func Train(samples []Race, current rating.Weights, cfg Configuration) Report {
	var eligible []Race
	for _, s := range samples {
		if valid(s) {
			eligible = append(eligible, s)
		}
	}
	sort.SliceStable(eligible, func(i, j int) bool {
		return eligible[i].Snapshot.CreatedAt.Before(eligible[j].Snapshot.CreatedAt.Time)
	})
	if len(eligible) > cfg.TrainingWindow {
		eligible = eligible[len(eligible)-cfg.TrainingWindow:]
	}
	notTrained := Report{SettledRaceCount: len(eligible), Weights: current}
	if len(eligible) < cfg.MinimumRaces {
		return notTrained
	}
	validationCount := min(cfg.ValidationRaces, max(1, len(eligible)/5))
	// A hard floor of 100 training races whatever the configuration says, as
	// in Swift. (Which means RacesKit's own trainer tests, run at 40 races,
	// cannot reach the fit; the tests here use enough races to.)
	if len(eligible)-validationCount < 100 {
		return notTrained
	}
	split := len(eligible) - validationCount
	train, validation := eligible[:split], eligible[split:]

	base := newParameters(current, commonFactorIDs(train))
	fitted := fit(train, base, cfg)
	candidate := fitted.makeWeights(current)

	baseline := logLoss(validation, base)
	candidateLoss := logLoss(validation, fitted)
	trainingLoss := logLoss(train, fitted)
	promoted := candidateLoss+cfg.MinimumImprovement < baseline

	weights := current
	if promoted {
		stamp := eligible[len(eligible)-1].Snapshot.CreatedAt.Unix()
		candidate.ID = fmt.Sprintf("learned-%d-%d", stamp, len(eligible))
		weights = candidate
	}
	return Report{
		Trained: true, SettledRaceCount: len(eligible), TrainingLogLoss: &trainingLoss,
		BaselineValidationLogLoss: &baseline, CandidateValidationLogLoss: &candidateLoss,
		Promoted: promoted, Weights: weights,
	}
}

type parameters struct {
	factorIDs      []rating.FactorID
	weights        []float64
	marketExponent float64
	formInfluence  float64
}

func newParameters(w rating.Weights, ids []rating.FactorID) parameters {
	p := parameters{factorIDs: ids, marketExponent: w.MarketExponent, formInfluence: w.FormInfluence}
	total := 0.0
	raw := make([]float64, len(ids))
	for i, id := range ids {
		raw[i] = math.Max(0, w.Weight(id))
		total += raw[i]
	}
	p.weights = make([]float64, len(ids))
	for i := range raw {
		if total > 0 {
			p.weights[i] = raw[i] / total
		} else {
			p.weights[i] = 1 / float64(max(1, len(ids)))
		}
	}
	return p
}

func (p parameters) makeWeights(original rating.Weights) rating.Weights {
	result := original.Clone()
	originalTotal, total := 0.0, 0.0
	for _, id := range p.factorIDs {
		originalTotal += math.Max(0, original.Weight(id))
	}
	for _, w := range p.weights {
		total += w
	}
	scale := 1.0
	if originalTotal > 0 && total > 0 {
		scale = originalTotal / total
	}
	for i, id := range p.factorIDs {
		result.FactorWeights[string(id)] = p.weights[i] * scale
	}
	result.MarketExponent = p.marketExponent
	result.FormInfluence = p.formInfluence
	return result
}

func commonFactorIDs(samples []Race) []rating.FactorID {
	if len(samples) == 0 {
		return nil
	}
	var out []rating.FactorID
	for _, f := range samples[0].Snapshot.FactorIDs {
		all := true
		for _, s := range samples {
			if !contains(s.Snapshot.FactorIDs, f) {
				all = false
				break
			}
		}
		if all {
			out = append(out, f)
		}
	}
	return out
}

func contains(ids []rating.FactorID, f rating.FactorID) bool {
	for _, id := range ids {
		if id == f {
			return true
		}
	}
	return false
}

func fit(samples []Race, start parameters, cfg Configuration) parameters {
	p := start
	p.weights = append([]float64(nil), start.weights...)
	if len(p.factorIDs) == 0 {
		return p
	}
	n := float64(len(samples))
	for range cfg.Epochs {
		gw := make([]float64, len(p.weights))
		ga, gb := 0.0, 0.0
		for _, s := range samples {
			result := probabilities(s, p)
			winner := indexOf(s.Snapshot.RunnerIDs, s.WinnerID)
			if winner < 0 {
				continue
			}
			for fi := range p.weights {
				z := zRow(s, fi, p)
				gw[fi] += -p.formInfluence * (z[winner] - dot(z, result))
			}
			marketLog := make([]float64, len(s.Snapshot.MarketProbabilities))
			for i, m := range s.Snapshot.MarketProbabilities {
				marketLog[i] = math.Log(math.Max(m, 1e-12))
			}
			ga += -(marketLog[winner] - dot(marketLog, result))
			form := formScores(s, p)
			gb += -(form[winner] - dot(form, result))
		}
		for i := range p.weights {
			gw[i] = gw[i]/n + cfg.Regularisation*2*(p.weights[i]-start.weights[i])
			p.weights[i] -= cfg.LearningRate * gw[i]
		}
		projectSimplex(p.weights)
		ga = ga/n + cfg.Regularisation*2*(p.marketExponent-start.marketExponent)
		gb = gb/n + cfg.Regularisation*2*(p.formInfluence-start.formInfluence)
		p.marketExponent -= cfg.LearningRate * ga
		p.formInfluence -= cfg.LearningRate * gb
		p.marketExponent = math.Min(cfg.MarketExponentRange.Upper, math.Max(cfg.MarketExponentRange.Lower, p.marketExponent))
		p.formInfluence = math.Min(cfg.FormInfluenceRange.Upper, math.Max(cfg.FormInfluenceRange.Lower, p.formInfluence))
	}
	return p
}

func probabilities(s Race, p parameters) []float64 {
	form := formScores(s, p)
	return rating.Combine(s.Snapshot.MarketProbabilities, form, p.marketExponent, p.formInfluence)
}

func formScores(s Race, p parameters) []float64 {
	out := make([]float64, len(s.Snapshot.RunnerIDs))
	for fi, w := range p.weights {
		z := zRow(s, fi, p)
		for i := range out {
			out[i] += w * z[i]
		}
	}
	return out
}

func zRow(s Race, fi int, p parameters) []float64 {
	if fi < len(p.factorIDs) {
		for si, id := range s.Snapshot.FactorIDs {
			if id == p.factorIDs[fi] && si < len(s.Snapshot.ZScores) {
				return s.Snapshot.ZScores[si]
			}
		}
	}
	return make([]float64, len(s.Snapshot.RunnerIDs))
}

// LogLoss of a weight set over settled races, exported for the back-test.
func logLoss(samples []Race, p parameters) float64 {
	if len(samples) == 0 {
		return math.Inf(1)
	}
	total, count := 0.0, 0
	for _, s := range samples {
		winner := indexOf(s.Snapshot.RunnerIDs, s.WinnerID)
		if winner < 0 {
			continue
		}
		total += -math.Log(math.Max(probabilities(s, p)[winner], 1e-12))
		count++
	}
	if count == 0 {
		return math.Inf(1)
	}
	return total / float64(count)
}

// LogLoss of the given weights over settled races, using each snapshot's
// frozen z-scores. Used by the back-test.
func LogLoss(samples []Race, w rating.Weights) float64 {
	return logLoss(samples, newParametersRaw(w, samples))
}

// newParametersRaw keeps the weights as given rather than renormalising, so a
// back-test scores exactly what the rater would.
func newParametersRaw(w rating.Weights, samples []Race) parameters {
	ids := commonFactorIDs(samples)
	p := parameters{factorIDs: ids, marketExponent: w.MarketExponent, formInfluence: w.FormInfluence}
	for _, id := range ids {
		p.weights = append(p.weights, w.Weight(id))
	}
	return p
}

func valid(s Race) bool {
	n := len(s.Snapshot.RunnerIDs)
	if n < 2 || len(s.Snapshot.MarketProbabilities) != n || len(s.Snapshot.FactorIDs) != len(s.Snapshot.ZScores) {
		return false
	}
	for _, z := range s.Snapshot.ZScores {
		if len(z) != n {
			return false
		}
	}
	return indexOf(s.Snapshot.RunnerIDs, s.WinnerID) >= 0
}

func projectSimplex(values []float64) {
	if len(values) == 0 {
		return
	}
	sorted := append([]float64(nil), values...)
	sort.Sort(sort.Reverse(sort.Float64Slice(sorted)))
	cumulative := 0.0
	rho := -1
	for i, v := range sorted {
		cumulative += v
		if v+(1-cumulative)/float64(i+1) > 0 {
			rho = i
		}
	}
	if rho < 0 {
		for i := range values {
			values[i] = 1 / float64(len(values))
		}
		return
	}
	sum := 0.0
	for _, v := range sorted[:rho+1] {
		sum += v
	}
	theta := (sum - 1) / float64(rho+1)
	for i := range values {
		values[i] = math.Max(0, values[i]-theta)
	}
}

func dot(a, b []float64) float64 {
	s := 0.0
	for i := range a {
		s += a[i] * b[i]
	}
	return s
}

func indexOf(ids []string, id string) int {
	for i, v := range ids {
		if v == id {
			return i
		}
	}
	return -1
}
