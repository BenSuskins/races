package tracking

import (
	"fmt"
	"math"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
)

// TipRecord owns the mutable data in a tip and exposes independent snapshots.
// Tip is the wire and storage representation; transitions operate on records.
type TipRecord struct{ tip Tip }

func RestoreTipRecord(tip Tip) (TipRecord, error) {
	if tip.RaceID == "" {
		return TipRecord{}, fmt.Errorf("tip: missing race ID")
	}
	if tip.Outcome != nil {
		switch tip.Outcome.Kind {
		case Won, Lost, NonRunner, Abandoned, Unresolved, Expired:
		default:
			return TipRecord{}, fmt.Errorf("tip: unknown outcome %q", tip.Outcome.Kind)
		}
	}
	return TipRecord{tip: copyTip(tip)}, nil
}

func (record TipRecord) Snapshot() Tip { return copyTip(record.tip) }

func EvaluateTip(existing *TipRecord, candidate Tip, now time.Time) (RecordOutcome, *TipRecord, error) {
	if candidate.RaceID == "" {
		return "", nil, fmt.Errorf("tip: missing race ID")
	}
	if candidate.Outcome != nil || candidate.SealedAt != nil {
		return "", nil, fmt.Errorf("tip: candidate is already sealed or settled")
	}
	var previous *Tip
	if existing != nil {
		if existing.tip.RaceID != candidate.RaceID {
			return "", nil, fmt.Errorf("tip: race ID mismatch")
		}
		snapshot := existing.Snapshot()
		previous = &snapshot
	}
	outcome, tip := Decide(previous, candidate, now)
	if tip == nil {
		return outcome, nil, nil
	}
	next, err := RestoreTipRecord(*tip)
	if err != nil {
		return "", nil, err
	}
	return outcome, &next, nil
}

func (record TipRecord) Reconcile(result *domain.RaceResult, prices map[string]float64, abandoned bool, now time.Time) (TipRecord, error) {
	if record.tip.RaceID == "" {
		return TipRecord{}, fmt.Errorf("tip: missing race ID")
	}
	if result != nil && result.ID != record.tip.RaceID {
		return TipRecord{}, fmt.Errorf("tip: result race ID mismatch")
	}
	if outcome := record.tip.Outcome; outcome != nil && (outcome.IsSettled() || outcome.IsVoid()) {
		return TipRecord{}, fmt.Errorf("tip: outcome is already final")
	}
	return RestoreTipRecord(Settle(record.tip, result, prices, abandoned, now))
}

func (record TipRecord) WithStartingPrices(prices map[string]float64) (TipRecord, bool, error) {
	tip := record.Snapshot()
	if tip.RaceID == "" || tip.Outcome == nil || !tip.Outcome.IsSettled() {
		return TipRecord{}, false, fmt.Errorf("tip: starting prices require a settled outcome")
	}
	changed := false
	if price, ok := prices[tip.SelectionHorseID]; ok && validStartingPrice(price) && tip.Outcome.BetfairSP == nil {
		tip.Outcome.BetfairSP = &price
		changed = true
	}
	if favourite := tip.FavouriteOutcome; favourite != nil && favourite.BetfairSP == nil {
		if price, ok := prices[favourite.HorseID]; ok && validStartingPrice(price) {
			favourite.BetfairSP = &price
			changed = true
		}
	}
	next, err := RestoreTipRecord(tip)
	return next, changed, err
}

func validStartingPrice(price float64) bool {
	return price > 1 && !math.IsInf(price, 0) && !math.IsNaN(price)
}
