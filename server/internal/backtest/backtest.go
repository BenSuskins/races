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
	"math"
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
}

// Arm is one model's performance over the replayed races.
type Arm struct {
	Races      int           `json:"races"`
	Wins       int           `json:"wins"`
	StrikeRate *float64      `json:"strikeRate,omitempty"`
	LogLoss    *float64      `json:"logLoss,omitempty"`
	Brier      *float64      `json:"brier,omitempty"`
	ROI        *tracking.ROI `json:"roi,omitempty"`
}

// Report compares the weights against the market over the same races.
type Report struct {
	WeightsID string `json:"weightsID"`
	From      string `json:"from,omitempty"`
	To        string `json:"to,omitempty"`
	// Rerated: races re-rated from the stored card and seal-time prices.
	Rerated Arm `json:"rerated"`
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
		"Strike-rate factors read today's archive, which includes results after each race; they ship at zero weight, but a set that weights them is optimistic here.",
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
	if _, err := st.LoadDocument(ctx, "archive", archive); err != nil {
		return rep, err
	}
	rater := rating.NewRater(w)
	var model, fav, market acc
	for _, row := range rows {
		t := row.Tip
		if row.Source != "server" || !t.IsSealed() || t.OffAt == nil {
			continue
		}
		if (!from.IsZero() && t.OffAt.Before(from)) || (!to.IsZero() && !t.OffAt.Before(to)) {
			continue
		}
		race, err := st.Race(ctx, t.RaceID)
		if err != nil || race == nil {
			continue
		}
		result, err := st.Result(ctx, t.RaceID)
		if err != nil || result == nil || result.Winner() == nil {
			continue
		}
		snap, _ := st.LatestSnapshot(ctx, t.RaceID, "seal")
		a := rater.Rate(*race, snap, archive, t.SealedAt.Time)
		sel := a.Selection()
		if sel == nil {
			continue
		}
		winner := result.Winner().HorseID
		var bsps map[string]float64
		if t.MarketReference != nil {
			sps, _ := st.StartingPrices(ctx, []string{t.MarketReference.MarketID})
			bsps = t.MarketReference.StartingPrices(sps)
		}
		model.add(sel.HorseID == winner, probOf(a, winner), sel.WinProbability, price(bsps, sel.HorseID))
		if f := a.MarketFavourite(); f != nil {
			fav.add(f.HorseID == winner, math.NaN(), *f.MarketProbability, price(bsps, f.HorseID))
			for _, r := range a.Runners {
				if r.HorseID == winner && r.MarketProbability != nil {
					market.addLoss(*r.MarketProbability)
				}
			}
		}
	}
	rep.Rerated, rep.Favourite = model.arm(), fav.arm()
	rep.MarketLogLoss = market.logLoss()

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
	case rep.Rerated.LogLoss != nil && rep.MarketLogLoss != nil:
		b := *rep.Rerated.LogLoss <= *rep.MarketLogLoss+0.005
		rep.BeatsMarket = &b
	case rep.SnapshotLogLoss != nil && rep.SnapshotMarketLogLoss != nil:
		b := *rep.SnapshotLogLoss <= *rep.SnapshotMarketLogLoss+0.005
		rep.BeatsMarket = &b
	}
	return rep, nil
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
	races, wins, bets int
	lossSum, brier    float64
	lossN             int
	returned          float64
}

func (a *acc) add(won bool, winnerProb, selProb, bsp float64) {
	a.races++
	actual := 0.0
	if won {
		a.wins++
		actual = 1
	}
	a.brier += (selProb - actual) * (selProb - actual)
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
	arm := Arm{Races: a.races, Wins: a.wins, LogLoss: a.logLoss()}
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
