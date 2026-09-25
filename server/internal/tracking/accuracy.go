package tracking

import "math"

// MinimumSampleForROI: below this, level-stakes ROI is noise.
const MinimumSampleForROI = 50

// DefaultCommission is Betfair's base rate.
const DefaultCommission = 0.05

// ROI is the return on a flat one-point stake.
type ROI struct {
	Bets     int     `json:"bets"`
	Returned float64 `json:"returned"`
}

// Subset is performance over part of the record.
type Subset struct {
	Settled int  `json:"settled"`
	Wins    int  `json:"wins"`
	ROI     *ROI `json:"roi,omitempty"`
}

// WilsonInterval is the 95% interval for a strike rate.
type WilsonInterval struct {
	Lower float64 `json:"lower"`
	Upper float64 `json:"upper"`
}

// Report is what the tips actually did. Three things here stop the model
// flattering itself: the favourite baseline, the agree/disagree split, and
// separate denominators for strike rate and ROI.
type Report struct {
	Total                     int             `json:"total"`
	Settled                   int             `json:"settled"`
	Wins                      int             `json:"wins"`
	Voided                    int             `json:"voided"`
	Unresolved                int             `json:"unresolved"`
	Expired                   int             `json:"expired"`
	Pending                   int             `json:"pending"`
	Coverage                  float64         `json:"coverage"`
	ExpectedWins              float64         `json:"expectedWins"`
	BrierScore                *float64        `json:"brierScore,omitempty"`
	ROI                       *ROI            `json:"roi,omitempty"`
	SettledWithoutPrice       int             `json:"settledWithoutPrice"`
	FavouriteBaseline         Subset          `json:"favouriteBaseline"`
	BenchmarkedModel          Subset          `json:"benchmarkedModel"`
	ModelWilson               *WilsonInterval `json:"modelWilson,omitempty"`
	FavouriteWilson           *WilsonInterval `json:"favouriteWilson,omitempty"`
	WhenAgreeingWithFavourite Subset          `json:"whenAgreeingWithFavourite"`
	WhenDisagreeing           Subset          `json:"whenDisagreeing"`
}

type tally struct {
	settled, wins, bets int
	returned            float64
}

func (t tally) subset() Subset {
	s := Subset{Settled: t.settled, Wins: t.wins}
	if t.bets > 0 {
		s.ROI = &ROI{Bets: t.bets, Returned: t.returned}
	}
	return s
}

// Accuracy builds the report. The same arithmetic as AccuracyCalculator.
func Accuracy(tips []Tip, commission float64) Report {
	var r Report
	r.Total = len(tips)
	var brier, roiReturned float64
	roiBets := 0
	var fav, agreed, disagreed, benchmarkModel tally

	for _, t := range tips {
		switch {
		case t.Outcome == nil:
			r.Pending++
			continue
		case t.Outcome.Kind == Unresolved:
			r.Unresolved++
			continue
		case t.Outcome.Kind == Expired:
			r.Expired++
			continue
		case t.Outcome.IsVoid():
			r.Voided++
			continue
		}
		r.Settled++
		won := t.Outcome.IsWin()
		if won {
			r.Wins++
		}
		r.ExpectedWins += t.PredictedProbability
		actual := 0.0
		if won {
			actual = 1
		}
		brier += math.Pow(t.PredictedProbability-actual, 2)

		agree := t.AgreedWithFavourite
		if sp := t.Outcome.BetfairSP; sp != nil && *sp > 1 {
			roiBets++
			payout := returnFor(won, *sp, commission)
			roiReturned += payout
			if agree != nil && *agree {
				agreed.bets++
				agreed.returned += payout
			} else if agree != nil {
				disagreed.bets++
				disagreed.returned += payout
			}
		} else {
			r.SettledWithoutPrice++
		}
		if agree != nil && *agree {
			agreed.settled++
			if won {
				agreed.wins++
			}
		} else if agree != nil {
			disagreed.settled++
			if won {
				disagreed.wins++
			}
		}
		if f := t.FavouriteOutcome; f != nil {
			fav.settled++
			if f.Won {
				fav.wins++
			}
			benchmarkModel.settled++
			if won {
				benchmarkModel.wins++
			}
			if f.BetfairSP != nil && *f.BetfairSP > 1 {
				fav.bets++
				fav.returned += returnFor(f.Won, *f.BetfairSP, commission)
			}
		}
	}

	finished := r.Settled + r.Voided + r.Unresolved + r.Expired
	r.Coverage = 1
	if finished > 0 {
		r.Coverage = float64(r.Settled+r.Voided) / float64(finished)
	}
	if r.Settled > 0 {
		b := brier / float64(r.Settled)
		r.BrierScore = &b
	}
	if roiBets > 0 {
		r.ROI = &ROI{Bets: roiBets, Returned: roiReturned}
	}
	r.FavouriteBaseline = fav.subset()
	r.BenchmarkedModel = benchmarkModel.subset()
	r.ModelWilson = Wilson(benchmarkModel.wins, benchmarkModel.settled)
	r.FavouriteWilson = Wilson(fav.wins, fav.settled)
	r.WhenAgreeingWithFavourite = agreed.subset()
	r.WhenDisagreeing = disagreed.subset()
	return r
}

// Wilson returns a two-sided 95% Wilson score interval, or nil without data.
func Wilson(wins, trials int) *WilsonInterval {
	if trials <= 0 || wins < 0 || wins > trials {
		return nil
	}
	const z = 1.959963984540054
	n := float64(trials)
	p := float64(wins) / n
	z2 := z * z
	denominator := 1 + z2/n
	center := (p + z2/(2*n)) / denominator
	halfWidth := z * math.Sqrt((p*(1-p)+z2/(4*n))/n) / denominator
	return &WilsonInterval{Lower: math.Max(0, center-halfWidth), Upper: math.Min(1, center+halfWidth)}
}

func returnFor(won bool, price, commission float64) float64 {
	if !won {
		return 0
	}
	return 1 + (price-1)*(1-math.Max(0, math.Min(commission, 1)))
}
