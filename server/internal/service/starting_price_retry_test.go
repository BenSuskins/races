package service

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
)

func TestStartingPriceArrivesAfterResult(t *testing.T) {
	ctx := context.Background()
	s, racing, markets, clock, race, _ := setup(t)
	s.Execute(ctx, Everything)
	clock.t = race.OffDateTime.Add(-3 * time.Minute)
	if err := s.SealTips(ctx); err != nil {
		t.Fatal(err)
	}
	row, err := s.Store.Tip(ctx, race.ID)
	if err != nil || row == nil {
		t.Fatal("missing tip", err)
	}
	selection := row.Tip.SelectionHorseID
	selectionID := row.Tip.MarketReference.SelectionIDsByHorseID[selection]
	racing.results = []domain.RaceResult{result(race, selection)}
	clock.t = race.OffDateTime.Add(10 * time.Minute)
	if _, err := s.CollectResults(ctx); err != nil {
		t.Fatal(err)
	}
	row, _ = s.Store.Tip(ctx, race.ID)
	if row.Tip.Outcome == nil || !row.Tip.Outcome.IsSettled() || row.Tip.Outcome.BetfairSP != nil {
		t.Fatal("test requires a result that settles before its starting price")
	}
	before, _ := json.Marshal(row.Tip)
	markets.spErr = errors.New("temporary price failure")
	ingestion, err := s.CollectResults(ctx)
	if err != nil || !ingestion.PricesFailed {
		t.Fatalf("price failure must remain visible: %+v, %v", ingestion, err)
	}
	markets.spErr = nil
	markets.sps = map[string]map[int64]float64{"1.1": {selectionID: 3.1}}
	clock.t = clock.t.Add(15 * time.Minute)
	if _, err := s.CollectResults(ctx); err != nil {
		t.Fatal(err)
	}
	row, _ = s.Store.Tip(ctx, race.ID)
	if row.Tip.Outcome.BetfairSP == nil || *row.Tip.Outcome.BetfairSP != 3.1 {
		t.Fatal("starting price remains missing after the provider makes 3.1 available")
	}
	if row.Tip.FavouriteOutcome != nil {
		row.Tip.FavouriteOutcome.BetfairSP = nil
	}
	row.Tip.Outcome.BetfairSP = nil
	after, _ := json.Marshal(row.Tip)
	if string(before) != string(after) {
		t.Fatal("price retry changes the frozen tip or settled outcome")
	}
}
