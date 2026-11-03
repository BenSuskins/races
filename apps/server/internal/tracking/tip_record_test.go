package tracking

import (
	"math"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
)

func TestTipRecordProtectsSnapshotsAndSealedState(t *testing.T) {
	original := makeTip(tipOpts{ref: &domain.MarketReference{MarketID: "market", SelectionIDsByHorseID: map[string]int64{"hrs_1": 1}}})
	original.SealedAt = domain.Ptr(off.Add(-time.Minute))
	record, err := RestoreTipRecord(original)
	if err != nil {
		t.Fatal(err)
	}
	original.MarketReference.SelectionIDsByHorseID["hrs_1"] = 2
	snapshot := record.Snapshot()
	snapshot.MarketReference.SelectionIDsByHorseID["hrs_1"] = 3
	if record.Snapshot().MarketReference.SelectionIDsByHorseID["hrs_1"] != 1 {
		t.Fatal("sealed record changed through an external reference")
	}
	outcome, next, err := EvaluateTip(&record, makeTip(tipOpts{}), off.Add(-time.Second))
	if err != nil || outcome != RejectedAlreadySealed || next != nil {
		t.Fatalf("sealed record was replaced: %v, %v", outcome, err)
	}
}

func TestTipRecordSettlesOnceAndAddsMissingStartingPrices(t *testing.T) {
	tip := makeTip(tipOpts{favourite: sp("hrs_2")})
	tip.SealedAt = domain.Ptr(off.Add(-time.Minute))
	record, err := RestoreTipRecord(tip)
	if err != nil {
		t.Fatal(err)
	}
	raceResult := result([][2]string{{"hrs_1", "1"}, {"hrs_2", "2"}, {"hrs_3", "3"}}, nil)
	settled, err := record.Reconcile(raceResult, nil, false, off)
	if err != nil || settled.Snapshot().Outcome.Kind != Won {
		t.Fatalf("settlement: %+v, %v", settled.Snapshot(), err)
	}
	if _, err := settled.Reconcile(raceResult, nil, false, off); err == nil {
		t.Fatal("settled record accepted a second outcome")
	}
	priced, changed, err := settled.WithStartingPrices(map[string]float64{"hrs_1": 2.5, "hrs_2": 4})
	if err != nil || !changed {
		t.Fatalf("missing prices were not applied: %v", err)
	}
	got := priced.Snapshot()
	if *got.Outcome.BetfairSP != 2.5 || *got.FavouriteOutcome.BetfairSP != 4 || got.SelectionHorseID != tip.SelectionHorseID || !got.SealedAt.Equal(tip.SealedAt.Time) {
		t.Fatal("prices changed sealed evidence")
	}
	if settled.Snapshot().Outcome.BetfairSP != nil {
		t.Fatal("price transition mutated its source")
	}
	again, changed, err := priced.WithStartingPrices(map[string]float64{"hrs_1": 8})
	if err != nil || changed || *again.Snapshot().Outcome.BetfairSP != 2.5 {
		t.Fatal("existing price was replaced")
	}
}

func TestTipRecordRestorationRefusesInvalidIdentity(t *testing.T) {
	if _, err := RestoreTipRecord(Tip{}); err == nil {
		t.Fatal("missing race ID accepted")
	}
	tip := makeTip(tipOpts{outcome: &Outcome{Kind: "invalid"}})
	if _, err := RestoreTipRecord(tip); err == nil {
		t.Fatal("unknown outcome accepted")
	}
}

func TestTipRecordRejectsCandidateWithAnOutcome(t *testing.T) {
	candidate := makeTip(tipOpts{outcome: &Outcome{Kind: Won}})
	if _, _, err := EvaluateTip(nil, candidate, off.Add(-time.Hour)); err == nil {
		t.Fatal("a new assessment cannot arrive settled")
	}
}

func TestTipRecordIgnoresInvalidStartingPrices(t *testing.T) {
	tip := makeTip(tipOpts{outcome: &Outcome{Kind: Won}})
	record, err := RestoreTipRecord(tip)
	if err != nil {
		t.Fatal(err)
	}
	for _, price := range []float64{0, 1, -1, math.Inf(1), math.NaN()} {
		updated, changed, err := record.WithStartingPrices(map[string]float64{tip.SelectionHorseID: price})
		if err != nil || changed || updated.Snapshot().Outcome.BetfairSP != nil {
			t.Fatalf("accepted invalid starting price %v", price)
		}
	}
}
