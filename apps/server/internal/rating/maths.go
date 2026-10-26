package rating

import "math"

// ZScores standardises within the race, clipped to ±clip.
//
// A runner with no value gets 0 (race-neutral, never the worst). When fewer
// than two runners have a value, or all are identical, everyone gets 0 — a
// factor that cannot discriminate contributes nothing.
func ZScores(values []*float64, clip float64) []float64 {
	out := make([]float64, len(values))
	var present []float64
	for _, v := range values {
		if v != nil && isFinite(*v) {
			present = append(present, *v)
		}
	}
	if len(present) < 2 {
		return out
	}
	n := float64(len(present))
	mean := 0.0
	for _, v := range present {
		mean += v
	}
	mean /= n
	variance := 0.0
	for _, v := range present {
		variance += (v - mean) * (v - mean)
	}
	sd := math.Sqrt(variance / n)
	if sd <= 1e-9 {
		return out
	}
	for i, v := range values {
		if v == nil || !isFinite(*v) {
			continue
		}
		out[i] = math.Min(math.Max((*v-mean)/sd, -clip), clip)
	}
	return out
}

func isFinite(v float64) bool { return !math.IsInf(v, 0) && !math.IsNaN(v) }

// OverroundMethod is how the book's margin comes out.
type OverroundMethod string

const (
	Proportional OverroundMethod = "proportional"
	Power        OverroundMethod = "power"
)

// ImpliedProbability of one runner before de-vigging: mid of back and lay when
// the spread is sane, then back, then last traded, then forecast. Withdrawn
// runners have none.
func ImpliedProbability(p RunnerPriceView) *float64 {
	if !p.IsActive {
		return nil
	}
	f := func(v float64) *float64 { return &v }
	if p.Back != nil && *p.Back > 1 && p.Lay != nil && *p.Lay > 1 && *p.Lay / *p.Back <= 1.35 {
		return f((1 / *p.Back + 1 / *p.Lay) / 2)
	}
	if p.Back != nil && *p.Back > 1 {
		return f(1 / *p.Back)
	}
	if p.LastTraded != nil && *p.LastTraded > 1 {
		return f(1 / *p.LastTraded)
	}
	if p.Forecast != nil && *p.Forecast > 1 {
		return f(1 / *p.Forecast)
	}
	return nil
}

// RunnerPriceView decouples the maths from the domain's JSON type.
type RunnerPriceView struct {
	Back, Lay, LastTraded, Forecast *float64
	IsActive                        bool
}

// Normalise so the present probabilities sum to one. Unpriced stay nil.
func Normalise(raw []*float64, method OverroundMethod) []*float64 {
	out := make([]*float64, len(raw))
	var present []float64
	for _, v := range raw {
		if v != nil && *v > 0 && isFinite(*v) {
			present = append(present, *v)
		}
	}
	if len(present) == 0 {
		return out
	}
	exponent := 1.0
	if method == Power {
		exponent = PowerExponent(present)
	}
	adjusted := make([]*float64, len(raw))
	total := 0.0
	for i, v := range raw {
		if v == nil || *v <= 0 || !isFinite(*v) {
			continue
		}
		a := *v
		if exponent != 1 {
			a = math.Pow(a, exponent)
		}
		adjusted[i] = &a
		total += a
	}
	if total <= 0 || !isFinite(total) {
		return out
	}
	for i, a := range adjusted {
		if a != nil {
			v := *a / total
			out[i] = &v
		}
	}
	return out
}

// PowerExponent solves Σpᵢ^k = 1 by bisection, falling back to 1 when the root
// is not bracketed.
func PowerExponent(p []float64) float64 {
	sum := func(k float64) float64 {
		s := 0.0
		for _, v := range p {
			s += math.Pow(v, k)
		}
		return s
	}
	low, high := 0.5, 3.0
	if !(sum(low) >= 1 && sum(high) <= 1) {
		return 1
	}
	for range 60 {
		mid := (low + high) / 2
		if sum(mid) > 1 {
			low = mid
		} else {
			high = mid
		}
	}
	return (low + high) / 2
}

// BookSum is the total before de-vigging; 1.03 is a 3% overround.
func BookSum(raw []*float64) float64 {
	s := 0.0
	for _, v := range raw {
		if v != nil && isFinite(*v) {
			s += *v
		}
	}
	return s
}
