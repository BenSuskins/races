package service

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/httpx"
	"github.com/bensuskins/races/server/internal/racingapi"
)

// racingDataContract tests facts used by the collection and settlement jobs.
// It runs against the service fake and the production adapter over HTTP.
func racingDataContract(t *testing.T, provider RacingData) {
	t.Helper()
	ctx := context.Background()
	cards, err := provider.Racecards(ctx, domain.Today, "gb", "ire")
	if err != nil {
		t.Fatal(err)
	}
	var card *domain.Race
	for i := range cards {
		if cards[i].ID == "rac_1001" {
			card = &cards[i]
			break
		}
	}
	if card == nil || card.CourseName != "Ascot" || len(card.Runners) != 4 || card.Runners[0].ID != "hrs_1" {
		t.Fatalf("wrong race card: %+v", card)
	}
	results, err := provider.TodaysResults(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var result *domain.RaceResult
	for i := range results {
		if results[i].ID == "rac_1001" {
			result = &results[i]
			break
		}
	}
	if result == nil || result.Winner() == nil || result.Winner().HorseID != "hrs_2" {
		t.Fatalf("wrong result: %+v", result)
	}
	if ran, known := result.DidRun("hrs_3"); !known || ran {
		t.Fatalf("absent horse must be a confirmed non-runner: ran=%v known=%v", ran, known)
	}
	if ran, known := result.DidRun("hrs_1"); !known || !ran {
		t.Fatalf("listed horse must have run: ran=%v known=%v", ran, known)
	}
	tomorrow, err := provider.Racecards(ctx, domain.Tomorrow, "gb", "ire")
	if err != nil || len(tomorrow) != 0 {
		t.Fatalf("empty tomorrow: %+v, %v", tomorrow, err)
	}
}

func TestRacingDataAdapterContract(t *testing.T) {
	fake := &fakeRacing{
		cards:   []domain.Race{{ID: "rac_1001", CourseName: "Ascot", Runners: []domain.Runner{{ID: "hrs_1"}, {ID: "hrs_2"}, {ID: "hrs_3"}, {ID: "hrs_4"}}}},
		results: []domain.RaceResult{{ID: "rac_1001", Finishers: []domain.Finisher{{HorseID: "hrs_2", Position: domain.Finished(1)}, {HorseID: "hrs_1", Position: domain.Finished(2)}, {HorseID: "hrs_4", Position: domain.Finished(3)}}}},
	}
	t.Run("fake", func(t *testing.T) { racingDataContract(t, fake) })
	t.Run("HTTP adapter", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			username, password, ok := r.BasicAuth()
			if !ok || username != "user" || password != "password" {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			switch r.URL.Path {
			case "/v1/racecards/free":
				if r.URL.Query().Get("day") == "tomorrow" {
					_, _ = w.Write([]byte(`{"racecards":[]}`))
					return
				}
				data, err := os.ReadFile("../racingapi/testdata/racingapi-racecards-free.json")
				if err != nil {
					t.Error(err)
					http.Error(w, "fixture", 500)
					return
				}
				_, _ = w.Write(data)
			case "/v1/results/today/free":
				data, err := os.ReadFile("../racingapi/testdata/racingapi-results-today-free.json")
				if err != nil {
					t.Error(err)
					http.Error(w, "fixture", 500)
					return
				}
				_, _ = w.Write(data)
			default:
				http.NotFound(w, r)
			}
		}))
		t.Cleanup(server.Close)
		transport := httpx.New(server.URL, 0, server.Client())
		transport.Retry = httpx.NoRetry
		racingDataContract(t, racingapi.New(server.URL, "user", "password", transport))
	})
}
