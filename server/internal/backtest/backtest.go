// Package backtest replays history through any weight set.
//
// Two corpora, used together:
//
//   - Races the server sealed: the stored card plus the prices it was sealed
//     on, re-rated from scratch. Any change to the weights — form points, the
//     clip, the blend — is visible here.
//   - Frozen training snapshots, including those uploaded from a phone: the
//     z-scores and market probabilities as they were at the seal. Only factor
//     weights and the α/β blend can vary here, since the raw inputs are gone.
//
// Both report against the market, because the question is never "is this
// good?" but "is this better than the favourite?".
package backtest

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/store"
	"github.com/bensuskins/races/server/internal/tracking"
	"github.com/bensuskins/races/server/internal/training"
)

// Request selects the weights and the date range (London dates, inclusive).
type Request struct {
	WeightsID string          `json:"weightsID,omitempty"`
	Weights   *rating.Weights `json:"weights,omitempty"`
	From      string          `json:"from,omitempty"`
	To        string          `json:"to,omitempty"`
	Variants  []SweepVariant  `json:"variants,omitempty"`
}

type SweepVariant struct {
	Name      string                     `json:"name"`
	Overrides map[string]json.RawMessage `json:"overrides"`
}

type SweepReport struct {
	SharedCorpusID string          `json:"sharedCorpusID"`
	Reports        []VariantReport `json:"reports"`
}

type VariantReport struct {
	Name   string `json:"name"`
	Report Report `json:"report"`
}

// ApplyOverrides applies a named, allow-listed weight sweep to a cloned base.
func ApplyOverrides(base rating.Weights, variant SweepVariant) (rating.Weights, error) {
	if variant.Name == "" || len(variant.Overrides) == 0 {
		return rating.Weights{}, fmt.Errorf("each sweep variant needs a name and at least one override")
	}
	out := base.Clone()
	// The sweep's value policy uses the standard v2 gate. A variant can then
	// change that gate explicitly without changing its probability weights.
	out.MinimumValueProbability = rating.V2().MinimumValueProbability
	for field, raw := range variant.Overrides {
		if string(raw) == "null" {
			return rating.Weights{}, fmt.Errorf("null override %q is invalid", field)
		}
		var number float64
		switch field {
		case "overroundMethod":
			var method rating.OverroundMethod
			if err := json.Unmarshal(raw, &method); err != nil || (method != rating.Proportional && method != rating.Power) {
				return rating.Weights{}, fmt.Errorf("invalid overroundMethod")
			}
			out.OverroundMethod = method
			continue
		case "marketExponent", "formInfluence", "formInfluenceNoMarket", "clip", "minimumMarketCoverage", "formDecay", "formSeasonBreakPenalty", "formLongBreakPenalty", "minimumValueEdge", "minimumValueProbability":
			if err := json.Unmarshal(raw, &number); err != nil || math.IsNaN(number) || math.IsInf(number, 0) {
				return rating.Weights{}, fmt.Errorf("invalid numeric override %q", field)
			}
		default:
			const prefix = "factorWeights."
			if !strings.HasPrefix(field, prefix) {
				return rating.Weights{}, fmt.Errorf("unknown override %q", field)
			}
			factor := strings.TrimPrefix(field, prefix)
			known := false
			for _, id := range rating.AllFactors {
				if string(id) == factor {
					known = true
					break
				}
			}
			if !known {
				return rating.Weights{}, fmt.Errorf("unknown factor %q", factor)
			}
			if err := json.Unmarshal(raw, &number); err != nil || math.IsNaN(number) || math.IsInf(number, 0) || number < 0 || number > 1 {
				return rating.Weights{}, fmt.Errorf("invalid factor weight %q", factor)
			}
			out.FactorWeights[factor] = number
			continue
		}
		switch field {
		case "marketExponent":
			if number <= 0 || number > 4 {
				return rating.Weights{}, fmt.Errorf("marketExponent is out of range")
			}
			out.MarketExponent = number
		case "formInfluence":
			if number < 0 || number > 1 {
				return rating.Weights{}, fmt.Errorf("formInfluence is out of range")
			}
			out.FormInfluence = number
		case "formInfluenceNoMarket":
			if number < 0 || number > 1 {
				return rating.Weights{}, fmt.Errorf("formInfluenceNoMarket is out of range")
			}
			out.FormInfluenceNoMarket = number
		case "clip":
			if number <= 0 || number > 10 {
				return rating.Weights{}, fmt.Errorf("clip is out of range")
			}
			out.Clip = number
		case "minimumMarketCoverage":
			if number < 0 || number > 1 {
				return rating.Weights{}, fmt.Errorf("minimumMarketCoverage is out of range")
			}
			out.MinimumMarketCoverage = number
		case "formDecay":
			if number < 0 || number > 1 {
				return rating.Weights{}, fmt.Errorf("formDecay is out of range")
			}
			out.FormDecay = number
		case "formSeasonBreakPenalty":
			if number < 0 || number > 1 {
				return rating.Weights{}, fmt.Errorf("formSeasonBreakPenalty is out of range")
			}
			out.FormSeasonBreakPenalty = number
		case "formLongBreakPenalty":
			if number < 0 || number > 1 {
				return rating.Weights{}, fmt.Errorf("formLongBreakPenalty is out of range")
			}
			out.FormLongBreakPenalty = number
		case "minimumValueEdge":
			if number < -1 || number > 10 {
				return rating.Weights{}, fmt.Errorf("minimumValueEdge is out of range")
			}
			out.MinimumValueEdge = number
		case "minimumValueProbability":
			if number < 0 || number > 1 {
				return rating.Weights{}, fmt.Errorf("minimumValueProbability is out of range")
			}
			out.MinimumValueProbability = number
		}
	}
	return out, nil
}

// Arm is one model's performance over the replayed races.
type Arm struct {
	Races                  int           `json:"races"`
	Wins                   int           `json:"wins"`
	FavouriteAgreement     int           `json:"favouriteAgreement"`
	FavouriteComparisons   int           `json:"favouriteComparisons"`
	FavouriteAgreementRate *float64      `json:"favouriteAgreementRate,omitempty"`
	StrikeRate             *float64      `json:"strikeRate,omitempty"`
	LogLoss                *float64      `json:"logLoss,omitempty"`
	Brier                  *float64      `json:"brier,omitempty"`
	ROI                    *tracking.ROI `json:"roi,omitempty"`
}

// Report compares the weights against the market over the same races.
type Report struct {
	WeightsID string `json:"weightsID"`
	CorpusID  string `json:"corpusID"`
	From      string `json:"from,omitempty"`
	To        string `json:"to,omitempty"`
	// Rerated: races re-rated from the stored card and seal-time prices.
	Rerated            Arm `json:"rerated"`
	HighestProbability Arm `json:"highestProbability"`
	ValueSelection     Arm `json:"valueSelection"`
	// Favourite: backing the market favourite in those same races.
	Favourite Arm `json:"favourite"`
	// MarketLogLoss: the de-vigged market's own log loss on those races.
	MarketLogLoss *float64 `json:"marketLogLoss,omitempty"`
	// Snapshots: log loss over every frozen snapshot, device ones included.
	Snapshots             int      `json:"snapshots"`
	SnapshotLogLoss       *float64 `json:"snapshotLogLoss,omitempty"`
	SnapshotMarketLogLoss *float64 `json:"snapshotMarketLogLoss,omitempty"`
	// BeatsMarket applies docs/algorithm.md's bar:
	// logLoss(model) ≤ logLoss(market) + 0.005.
	BeatsMarket *bool    `json:"beatsMarket,omitempty"`
	Notes       []string `json:"notes"`
}

// Run replays the stored history.
func Run(ctx context.Context, st *store.Store, w rating.Weights, req Request) (Report, error) {
	rep := Report{WeightsID: w.ID, From: req.From, To: req.To, Notes: []string{
		"Archive factors use result facts recorded before each tip sealed.",
		"Legacy server tips without an immutable seal card are excluded; raw-payload recovery is not available yet.",
	}}
	var from, to time.Time
	if req.From != "" {
		from, _, _ = domain.DayWindow(req.From)
	}
	if req.To != "" {
		_, to, _ = domain.DayWindow(req.To)
	}

	rows, err := st.Tips(ctx, "", "")
	if err != nil {
		return rep, err
	}
	archive := tracking.NewArchive()
	rater := rating.NewRater(w)
	var highest, value, fav, market acc
	var corpus []string
	var raceDates []string
	missingSealCards := 0
	for _, row := range rows {
		t := row.Tip
		if row.Source != "server" || !t.IsSealed() || t.OffAt == nil {
			continue
		}
		if (!from.IsZero() && t.OffAt.Before(from)) || (!to.IsZero() && !t.OffAt.Before(to)) {
			continue
		}
		race, err := st.SealCard(ctx, t.RaceID)
		if err != nil || race == nil {
			missingSealCards++
			continue
		}
		result, err := st.Result(ctx, t.RaceID)
		if err != nil || result == nil || result.Winner() == nil {
			continue
		}
		facts, err := st.ResultFactsKnownBefore(ctx, t.SealedAt.Time)
		if err != nil {
			return rep, err
		}
		archive = tracking.NewArchive()
		for _, fact := range facts {
			if fact.ID != t.RaceID {
				archive.Ingest(fact)
			}
		}
		snap, _ := st.LatestSnapshot(ctx, t.RaceID, "seal")
		a := rater.Rate(*race, snap, archive, t.SealedAt.Time)
		highestSelection := selectRunner(a, "highestProbability", w)
		valueSelection := selectRunner(a, "valueSelection", w)
		if highestSelection == nil || valueSelection == nil {
			continue
		}
		corpus = append(corpus, t.RaceID)
		raceDates = append(raceDates, t.RaceDate)
		winner := result.Winner().HorseID
		var bsps map[string]float64
		if t.MarketReference != nil {
			sps, _ := st.StartingPrices(ctx, []string{t.MarketReference.MarketID})
			bsps = t.MarketReference.StartingPrices(sps)
		}
		var highestAgreement, valueAgreement *bool
		if f := a.MarketFavourite(); f != nil {
			highestAgreementValue := highestSelection.HorseID == f.HorseID
			valueAgreementValue := valueSelection.HorseID == f.HorseID
			highestAgreement, valueAgreement = &highestAgreementValue, &valueAgreementValue
			fav.add(f.HorseID == winner, math.NaN(), *f.MarketProbability, price(bsps, f.HorseID), nil)
			for _, r := range a.Runners {
				if r.HorseID == winner && r.MarketProbability != nil {
					market.addLoss(*r.MarketProbability)
				}
			}
		}
		highest.add(highestSelection.HorseID == winner, probOf(a, winner), highestSelection.WinProbability, price(bsps, highestSelection.HorseID), highestAgreement)
		value.add(valueSelection.HorseID == winner, probOf(a, winner), valueSelection.WinProbability, price(bsps, valueSelection.HorseID), valueAgreement)
	}
	if missingSealCards > 0 {
		rep.Notes = append(rep.Notes, fmt.Sprintf("Excluded %d sealed tips without a stored seal card.", missingSealCards))
	}
	rep.HighestProbability, rep.ValueSelection = highest.arm(), value.arm()
	rep.Rerated, rep.Favourite = rep.HighestProbability, fav.arm()
	rep.MarketLogLoss = market.logLoss()
	sort.Strings(corpus)
	sort.Strings(raceDates)
	if rep.From == "" && len(raceDates) > 0 {
		rep.From = raceDates[0]
	}
	if rep.To == "" && len(raceDates) > 0 {
		rep.To = raceDates[len(raceDates)-1]
	}
	corpusJSON, _ := json.Marshal(corpus)
	corpusHash := sha256.Sum256(corpusJSON)
	rep.CorpusID = hex.EncodeToString(corpusHash[:])

	samples, err := st.SettledTrainingSamples(ctx, from, to)
	if err != nil {
		return rep, err
	}
	rep.Snapshots = len(samples)
	if len(samples) > 0 {
		ll := training.LogLoss(samples, w)
		ml := training.LogLoss(samples, rating.MarketOnly())
		rep.SnapshotLogLoss, rep.SnapshotMarketLogLoss = finite(ll), finite(ml)
	}

	switch {
	case rep.HighestProbability.LogLoss != nil && rep.MarketLogLoss != nil:
		b := *rep.HighestProbability.LogLoss <= *rep.MarketLogLoss+0.005
		rep.BeatsMarket = &b
	case rep.SnapshotLogLoss != nil && rep.SnapshotMarketLogLoss != nil:
		b := *rep.SnapshotLogLoss <= *rep.SnapshotMarketLogLoss+0.005
		rep.BeatsMarket = &b
	}
	return rep, nil
}

func selectRunner(a rating.Assessment, policy string, weights rating.Weights) *rating.RunnerAssessment {
	if len(a.Runners) == 0 {
		return nil
	}
	switch policy {
	case "highestProbability":
		return &a.Runners[0]
	case "valueSelection":
		a.MinimumValueEdge = weights.MinimumValueEdge
		a.MinimumValueProbability = weights.MinimumValueProbability
		return a.Selection()
	default:
		return nil
	}
}

func probOf(a rating.Assessment, horseID string) float64 {
	for _, r := range a.Runners {
		if r.HorseID == horseID {
			return r.WinProbability
		}
	}
	return 0
}

func price(bsps map[string]float64, horseID string) float64 {
	if p, ok := bsps[horseID]; ok {
		return p
	}
	return 0
}

type acc struct {
	races, wins, bets                        int
	lossSum, brier                           float64
	lossN                                    int
	returned                                 float64
	favouriteAgreement, favouriteComparisons int
}

func (a *acc) add(won bool, winnerProb, selProb, bsp float64, agreement *bool) {
	a.races++
	actual := 0.0
	if won {
		a.wins++
		actual = 1
	}
	a.brier += (selProb - actual) * (selProb - actual)
	if agreement != nil {
		a.favouriteComparisons++
		if *agreement {
			a.favouriteAgreement++
		}
	}
	if !math.IsNaN(winnerProb) {
		a.addLoss(winnerProb)
	}
	if bsp > 1 {
		a.bets++
		if won {
			a.returned += 1 + (bsp-1)*(1-tracking.DefaultCommission)
		}
	}
}

func (a *acc) addLoss(p float64) {
	a.lossSum += -math.Log(math.Max(p, 1e-12))
	a.lossN++
}

func (a *acc) logLoss() *float64 {
	if a.lossN == 0 {
		return nil
	}
	return finite(a.lossSum / float64(a.lossN))
}

func (a *acc) arm() Arm {
	arm := Arm{Races: a.races, Wins: a.wins, LogLoss: a.logLoss(), FavouriteAgreement: a.favouriteAgreement, FavouriteComparisons: a.favouriteComparisons}
	if a.favouriteComparisons > 0 {
		rate := float64(a.favouriteAgreement) / float64(a.favouriteComparisons)
		arm.FavouriteAgreementRate = &rate
	}
	if a.races > 0 {
		sr, b := float64(a.wins)/float64(a.races), a.brier/float64(a.races)
		arm.StrikeRate, arm.Brier = &sr, &b
	}
	if a.bets > 0 {
		arm.ROI = &tracking.ROI{Bets: a.bets, Returned: a.returned}
	}
	return arm
}

func finite(v float64) *float64 {
	if math.IsInf(v, 0) || math.IsNaN(v) {
		return nil
	}
	return &v
}
