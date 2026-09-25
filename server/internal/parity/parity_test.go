// Package parity pins the Go rater to the Swift one it replaced.
//
// It rates the committed racecard fixture under every preset and writes the
// result to ios/RacesKit/Tests/RacesKitTests/Fixtures/server-golden-rating.json.
// RacesKit's ServerParityTests rates the same fixture with the Swift rater and
// asserts the same numbers, so the two cannot drift while both exist.
//
// Regenerate with: go test ./internal/parity -update
package parity

import (
	"encoding/json"
	"flag"
	"os"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/racingapi"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/testutil"
)

var update = flag.Bool("update", false, "rewrite the golden file")

const golden = "../../../ios/RacesKit/Tests/RacesKitTests/Fixtures/server-golden-rating.json"

// Market is the fixture market, by our horse id. Mixed shapes on purpose:
// back and lay, back alone, forecast alone.
func Market() map[string]map[string]domain.RunnerPrice {
	f := func(v float64) *float64 { return &v }
	return map[string]map[string]domain.RunnerPrice{
		"rac_1001": {
			"hrs_1": {BackPrice: f(1.7), LayPrice: f(1.75), IsActive: true},
			"hrs_2": {BackPrice: f(3.4), IsActive: true},
			"hrs_3": {ForecastPrice: f(8.5), IsActive: true},
			"hrs_4": {BackPrice: f(19), LayPrice: f(21), IsActive: true},
		},
		"rac_1002": {
			"hrs_5": {BackPrice: f(2.1), IsActive: true},
			"hrs_6": {LastTraded: f(1.9), IsActive: true},
		},
	}
}

type Runner struct {
	HorseID           string   `json:"horseID"`
	WinProbability    float64  `json:"winProbability"`
	FormScore         float64  `json:"formScore"`
	MarketProbability *float64 `json:"marketProbability,omitempty"`
}

type Case struct {
	RaceID      string   `json:"raceID"`
	WeightsID   string   `json:"weightsID"`
	WithMarket  bool     `json:"withMarket"`
	SelectionID string   `json:"selectionID"`
	Confidence  string   `json:"confidence"`
	Coverage    float64  `json:"coverage"`
	Runners     []Runner `json:"runners"`
}

func TestGolden(t *testing.T) {
	body, err := os.ReadFile("../racingapi/testdata/racingapi-racecards-free.json")
	if err != nil {
		t.Fatal(err)
	}
	races, err := racingapi.ParseRacecards(body, time.Date(2026, 9, 20, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	var cases []Case
	for _, w := range rating.Presets() {
		for _, race := range races {
			for _, withMarket := range []bool{true, false} {
				var m *domain.MarketSnapshot
				if withMarket {
					m = &domain.MarketSnapshot{Source: domain.SourceLiveExchange, IsDelayed: true, Prices: Market()[race.ID]}
				}
				a := rating.NewRater(w).Rate(race, m, nil, time.Unix(0, 0))
				c := Case{RaceID: race.ID, WeightsID: w.ID, WithMarket: withMarket, Confidence: string(a.Confidence), Coverage: a.MarketCoverage}
				if sel := a.Selection(); sel != nil {
					c.SelectionID = sel.HorseID
				}
				for _, r := range a.Runners {
					c.Runners = append(c.Runners, Runner{r.HorseID, r.WinProbability, r.FormScore, r.MarketProbability})
				}
				cases = append(cases, c)
			}
		}
	}
	out, _ := json.MarshalIndent(map[string]any{"cases": cases}, "", "  ")
	out = append(out, '\n')
	if *update {
		if err := os.WriteFile(golden, out, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	existing, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal("no golden file; run with -update:", err)
	}
	matches, err := testutil.CompareJSON(existing, out)
	if err != nil {
		t.Fatal(err)
	}
	if !matches {
		t.Fatal("the Go rater no longer matches the committed golden file. If the change is intended, regenerate with -update and run RacesKit's ServerParityTests.")
	}
}
