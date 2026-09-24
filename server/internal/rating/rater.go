package rating

import (
	"math"
	"sort"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
)

// ModelVersion is stamped on every assessment and tip.
const ModelVersion = "market-anchored-3"

// Contribution is what one factor did to one runner's chance.
type Contribution struct {
	Factor           FactorID     `json:"factor"`
	Label            string       `json:"label"`
	Detail           string       `json:"detail"`
	ZScore           *float64     `json:"zScore,omitempty"`
	Weight           float64      `json:"weight"`
	ProbabilityDelta float64      `json:"probabilityDelta"`
	Availability     Availability `json:"availability"`
}

// Confidence is low, medium or high.
type Confidence string

const (
	Low    Confidence = "low"
	Medium Confidence = "medium"
	High   Confidence = "high"
)

// RunnerAssessment is the model's view of one runner.
type RunnerAssessment struct {
	HorseID           string         `json:"horseID"`
	HorseName         string         `json:"horseName"`
	ClothNumber       *int           `json:"clothNumber,omitempty"`
	MarketProbability *float64       `json:"marketProbability,omitempty"`
	MarketBackPrice   *float64       `json:"marketBackPrice,omitempty"`
	FormScore         float64        `json:"formScore"`
	WinProbability    float64        `json:"winProbability"`
	Contributions     []Contribution `json:"contributions"`
}

// ValueEdge is expected value per unit staked: p × odds − 1.
func (r RunnerAssessment) ValueEdge() *float64 {
	if r.MarketBackPrice == nil || *r.MarketBackPrice <= 1 {
		return nil
	}
	v := r.WinProbability**r.MarketBackPrice - 1
	return &v
}

// TrainingSnapshot freezes the model inputs at tip time — with no result, so
// the future cannot leak into a past prediction.
type TrainingSnapshot struct {
	RaceID              string         `json:"raceID"`
	CreatedAt           domain.Instant `json:"createdAt"`
	RunnerIDs           []string       `json:"runnerIDs"`
	MarketProbabilities []float64      `json:"marketProbabilities"`
	FactorIDs           []FactorID     `json:"factorIDs"`
	// ZScores[factorIndex][runnerIndex].
	ZScores [][]float64 `json:"zScores"`
}

// Assessment is the rated race.
type Assessment struct {
	RaceID                  string               `json:"raceID"`
	GeneratedAt             domain.Instant       `json:"generatedAt"`
	ModelVersion            string               `json:"modelVersion"`
	WeightsID               string               `json:"weightsID"`
	MarketSource            *domain.MarketSource `json:"marketSource,omitempty"`
	MarketCoverage          float64              `json:"marketCoverage"`
	IsMarketDelayed         bool                 `json:"isMarketDelayed"`
	Runners                 []RunnerAssessment   `json:"runners"`
	Confidence              Confidence           `json:"confidence"`
	TrainingSnapshot        *TrainingSnapshot    `json:"trainingSnapshot,omitempty"`
	MinimumValueEdge        float64              `json:"minimumValueEdge"`
	MinimumValueProbability float64              `json:"minimumValueProbability"`
}

func (a Assessment) IsFormOnly() bool { return a.MarketSource == nil }

// Selection is the tip: the highest probability, unless a priced runner clears
// both value thresholds, in which case the best value edge.
func (a Assessment) Selection() *RunnerAssessment {
	if len(a.Runners) == 0 {
		return nil
	}
	if a.IsFormOnly() {
		return &a.Runners[0]
	}
	var best *RunnerAssessment
	for i := range a.Runners {
		r := &a.Runners[i]
		edge := r.ValueEdge()
		if edge == nil || *edge < a.MinimumValueEdge || r.WinProbability < a.MinimumValueProbability {
			continue
		}
		if best == nil {
			best = r
			continue
		}
		be := *best.ValueEdge()
		// Swift's max(by:) replaces only on strictly greater, so the first of
		// equal candidates wins; the same here.
		if *edge > be || (*edge == be && r.WinProbability > best.WinProbability) {
			best = r
		}
	}
	if best != nil {
		return best
	}
	return &a.Runners[0]
}

// MarketFavourite is the runner the market rates highest.
func (a Assessment) MarketFavourite() *RunnerAssessment {
	var fav *RunnerAssessment
	for i := range a.Runners {
		r := &a.Runners[i]
		if r.MarketProbability == nil {
			continue
		}
		// The first of equal maxima, as Swift's max(by:) returns.
		if fav == nil || *r.MarketProbability > *fav.MarketProbability {
			fav = r
		}
	}
	return fav
}

// AgreesWithMarket is nil when there is no selection or no favourite.
func (a Assessment) AgreesWithMarket() *bool {
	sel, fav := a.Selection(), a.MarketFavourite()
	if sel == nil || fav == nil {
		return nil
	}
	v := sel.HorseID == fav.HorseID
	return &v
}

// Rater is the rating engine: market-anchored probabilities, value-aware
// selection.
type Rater struct {
	Weights Weights
	Factors []Factor
}

func NewRater(w Weights) Rater { return Rater{Weights: w, Factors: DefaultFactors(w)} }

type reading struct {
	id      FactorID
	weight  float64
	values  []FactorValue
	zScores []float64
}

type anchor struct {
	probabilities []float64
	coverage      float64
	usable        bool
}

// Rate assesses one race. market may be nil; strikeRates may be nil.
func (rt Rater) Rate(race domain.Race, market *domain.MarketSnapshot, strikeRates StrikeRates, now time.Time) Assessment {
	w := rt.Weights
	runners := race.DeclaredRunners()
	if len(runners) == 0 {
		return Assessment{
			RaceID: race.ID, GeneratedAt: domain.At(now), ModelVersion: ModelVersion, WeightsID: w.ID,
			Runners: []RunnerAssessment{}, Confidence: Low,
			MinimumValueEdge: w.MinimumValueEdge, MinimumValueProbability: w.MinimumValueProbability,
		}
	}

	ctx := Context{Race: race, StrikeRates: strikeRates}
	readings := make([]reading, len(rt.Factors))
	for i, f := range rt.Factors {
		values := make([]FactorValue, len(runners))
		raws := make([]*float64, len(runners))
		for j, r := range runners {
			values[j] = f.Value(r, ctx)
			raws[j] = values[j].Raw
		}
		readings[i] = reading{id: f.ID(), weight: w.Weight(f.ID()), values: values, zScores: ZScores(raws, w.Clip)}
	}

	formScores := formScoresOf(readings, len(runners))
	a := rt.marketAnchor(runners, market)
	influence := w.FormInfluenceNoMarket
	if a.usable {
		influence = w.FormInfluence
	}
	probabilities := Combine(a.probabilities, formScores, w.MarketExponent, influence)
	deltas := rt.leaveOneOutDeltas(readings, probabilities, a, influence, len(runners))

	assessments := make([]RunnerAssessment, len(runners))
	for i, r := range runners {
		ra := RunnerAssessment{
			HorseID: r.ID, HorseName: r.Name, ClothNumber: r.ClothNumber,
			FormScore: formScores[i], WinProbability: probabilities[i],
		}
		if a.usable {
			p := a.probabilities[i]
			ra.MarketProbability = &p
		}
		if market != nil {
			if price, ok := market.Price(r.ID); ok {
				ra.MarketBackPrice = price.BackPrice
			}
		}
		for _, rd := range readings {
			c := Contribution{
				Factor: rd.id, Label: rd.id.Label(), Detail: rd.values[i].Display,
				Weight: rd.weight, Availability: rd.values[i].Availability,
			}
			if rd.values[i].Availability.IsAvailable() {
				z := rd.zScores[i]
				c.ZScore = &z
			}
			if d, ok := deltas[rd.id]; ok {
				c.ProbabilityDelta = d[i]
			}
			ra.Contributions = append(ra.Contributions, c)
		}
		assessments[i] = ra
	}
	// Swift's sort is not stable, but ties in a real-valued probability are
	// vanishingly rare; stable here keeps the output reproducible.
	sort.SliceStable(assessments, func(i, j int) bool { return assessments[i].WinProbability > assessments[j].WinProbability })

	result := Assessment{
		RaceID: race.ID, GeneratedAt: domain.At(now), ModelVersion: ModelVersion, WeightsID: w.ID,
		MarketCoverage: a.coverage, Runners: assessments,
		Confidence:       confidence(assessments, a.coverage),
		MinimumValueEdge: w.MinimumValueEdge, MinimumValueProbability: w.MinimumValueProbability,
	}
	if market != nil {
		result.IsMarketDelayed = market.IsDelayed
	}
	if a.usable {
		src := market.Source
		result.MarketSource = &src
		ids := make([]string, len(runners))
		for i, r := range runners {
			ids[i] = r.ID
		}
		snapshot := &TrainingSnapshot{
			RaceID: race.ID, CreatedAt: domain.At(now), RunnerIDs: ids,
			MarketProbabilities: append([]float64(nil), a.probabilities...),
		}
		for _, rd := range readings {
			snapshot.FactorIDs = append(snapshot.FactorIDs, rd.id)
			snapshot.ZScores = append(snapshot.ZScores, rd.zScores)
		}
		result.TrainingSnapshot = snapshot
	}
	return result
}

func formScoresOf(readings []reading, n int) []float64 {
	out := make([]float64, n)
	for i := range out {
		for _, rd := range readings {
			out[i] += rd.weight * rd.zScores[i]
		}
	}
	return out
}

func (rt Rater) marketAnchor(runners []domain.Runner, market *domain.MarketSnapshot) anchor {
	uniform := make([]float64, len(runners))
	for i := range uniform {
		uniform[i] = 1 / float64(len(runners))
	}
	if market == nil {
		return anchor{probabilities: uniform}
	}
	raw := make([]*float64, len(runners))
	var floor *float64
	priced := 0
	for i, r := range runners {
		price, ok := market.Price(r.ID)
		if !ok {
			continue
		}
		raw[i] = ImpliedProbability(RunnerPriceView{Back: price.BackPrice, Lay: price.LayPrice, LastTraded: price.LastTraded, Forecast: price.ForecastPrice, IsActive: price.IsActive})
		if raw[i] != nil {
			priced++
			if floor == nil || *raw[i] < *floor {
				v := *raw[i]
				floor = &v
			}
		}
	}
	coverage := float64(priced) / float64(len(runners))
	if coverage < rt.Weights.MinimumMarketCoverage || floor == nil {
		return anchor{probabilities: uniform, coverage: coverage}
	}
	filled := make([]*float64, len(raw))
	for i, v := range raw {
		if v == nil {
			filled[i] = floor
		} else {
			filled[i] = v
		}
	}
	normalised := Normalise(filled, rt.Weights.OverroundMethod)
	probs := make([]float64, len(runners))
	for i, v := range normalised {
		if v == nil {
			probs[i] = 1 / float64(len(runners))
		} else {
			probs[i] = *v
		}
	}
	return anchor{probabilities: probs, coverage: coverage, usable: true}
}

// Combine is the softmax of α·log(market) + β·form.
func Combine(market, form []float64, exponent, influence float64) []float64 {
	n := len(market)
	if n == 0 {
		return []float64{}
	}
	logs := make([]float64, n)
	peak := math.Inf(-1)
	for i := range logs {
		logs[i] = exponent*math.Log(math.Max(market[i], 1e-12)) + influence*form[i]
		peak = math.Max(peak, logs[i])
	}
	total := 0.0
	exps := make([]float64, n)
	for i, l := range logs {
		exps[i] = math.Exp(l - peak)
		total += exps[i]
	}
	out := make([]float64, n)
	if total <= 0 || !isFinite(total) {
		for i := range out {
			out[i] = 1 / float64(n)
		}
		return out
	}
	for i, e := range exps {
		out[i] = e / total
	}
	return out
}

func (rt Rater) leaveOneOutDeltas(readings []reading, baseline []float64, a anchor, influence float64, n int) map[FactorID][]float64 {
	deltas := map[FactorID][]float64{}
	for _, rd := range readings {
		if rd.weight == 0 {
			continue
		}
		var without []reading
		for _, other := range readings {
			if other.id != rd.id {
				without = append(without, other)
			}
		}
		probs := Combine(a.probabilities, formScoresOf(without, n), rt.Weights.MarketExponent, influence)
		d := make([]float64, n)
		for i := range d {
			d[i] = baseline[i] - probs[i]
		}
		deltas[rd.id] = d
	}
	return deltas
}

func confidence(runners []RunnerAssessment, coverage float64) Confidence {
	if len(runners) <= 1 {
		return Low
	}
	entropy := 0.0
	probs := make([]float64, len(runners))
	for i, r := range runners {
		probs[i] = r.WinProbability
		if r.WinProbability > 0 {
			entropy += r.WinProbability * math.Log(r.WinProbability)
		}
	}
	entropy = -entropy
	maxEntropy := math.Log(float64(len(runners)))
	if maxEntropy <= 0 {
		return Low
	}
	sort.Sort(sort.Reverse(sort.Float64Slice(probs)))
	score := (1-entropy/maxEntropy)*0.6 + (probs[0]-probs[1])*0.4
	if coverage > 0 {
		score += 0.1
	}
	switch {
	case score < 0.15:
		return Low
	case score < 0.30:
		return Medium
	}
	return High
}
