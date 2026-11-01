package service

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/betfair"
	"github.com/bensuskins/races/server/internal/httpx"
	"github.com/bensuskins/races/server/internal/matching"
)

const contractMarketID = "1.245678901"

func marketDataContract(t *testing.T, provider MarketData) {
	t.Helper()
	ctx := context.Background()
	markets, err := provider.Markets(ctx, "2026-09-22", "GB", "IE")
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, market := range markets {
		if market.ID == contractMarketID {
			found = market.Venue == "Ascot" && len(market.Runners) > 0 && market.Runners[0].ID == 12345678
		}
	}
	if !found {
		t.Fatalf("market catalogue missing expected selection: %+v", markets)
	}
	books, err := provider.Prices(ctx, []string{contractMarketID})
	if err != nil || len(books) != 1 {
		t.Fatalf("priced market: %+v, %v", books, err)
	}
	price, ok := books[0].Prices[12345678]
	if !ok || !price.IsActive || price.BackPrice == nil || *price.BackPrice != 2.4 {
		t.Fatalf("wrong selection price: %+v", price)
	}
	empty, err := provider.Prices(ctx, []string{"empty"})
	if err != nil {
		t.Fatal(err)
	}
	for _, book := range empty {
		for _, price := range book.Prices {
			if price.BackPrice != nil || price.LayPrice != nil || price.LastTraded != nil || price.ForecastPrice != nil {
				t.Fatalf("empty market gained a price: %+v", price)
			}
		}
	}
	settled, err := provider.StartingPrices(ctx, []string{contractMarketID})
	if err != nil || settled[contractMarketID][12345678] != 2.64 || settled[contractMarketID][22345678] != 5.2 {
		t.Fatalf("wrong settled prices: %+v, %v", settled, err)
	}
	if _, exists := settled[contractMarketID][32345678]; exists {
		t.Fatal("removed runner must not have a starting price")
	}
}

func TestMarketDataAdapterContract(t *testing.T) {
	fake := &fakeMarkets{
		markets: []matching.ExchangeMarket{{ID: contractMarketID, Venue: "Ascot", Runners: []matching.ExchangeRunner{{ID: 12345678}}}},
		prices:  map[string]map[int64]float64{contractMarketID: {12345678: 2.4}},
		sps:     map[string]map[int64]float64{contractMarketID: {12345678: 2.64, 22345678: 5.2}},
	}
	t.Run("fake", func(t *testing.T) { marketDataContract(t, fake) })
	t.Run("HTTP adapter", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/api/login" {
				_, _ = w.Write([]byte(`{"token":"TOKEN","status":"SUCCESS"}`))
				return
			}
			if r.Header.Get("X-Application") != "KEY" || r.Header.Get("X-Authentication") != "TOKEN" {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			var fixture string
			switch r.URL.Path {
			case "/listMarketCatalogue/":
				fixture = "betfair-listmarketcatalogue.json"
			case "/listMarketBook/":
				var request struct {
					MarketIDs       []string `json:"marketIds"`
					PriceProjection struct {
						PriceData []string `json:"priceData"`
					} `json:"priceProjection"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
					http.Error(w, "request", 400)
					return
				}
				if len(request.MarketIDs) == 1 && request.MarketIDs[0] == "empty" {
					_, _ = w.Write([]byte(`[{"marketId":"empty","runners":[{"selectionId":1,"status":"ACTIVE"}]}]`))
					return
				}
				fixture = "betfair-listmarketbook.json"
				if len(request.PriceProjection.PriceData) > 0 && request.PriceProjection.PriceData[0] == "SP_AVAILABLE" {
					fixture = "betfair-listmarketbook-settled.json"
				}
			default:
				http.NotFound(w, r)
				return
			}
			data, err := os.ReadFile("../betfair/testdata/" + fixture)
			if err != nil {
				t.Error(err)
				http.Error(w, "fixture", 500)
				return
			}
			_, _ = w.Write(data)
		}))
		t.Cleanup(server.Close)
		transport := httpx.New(server.URL, 0, server.Client())
		transport.Retry = httpx.NoRetry
		client := betfair.New(betfair.Credentials{AppKey: "KEY", Username: "user", Password: "password"}, transport, transport, func() time.Time { return time.Date(2026, 9, 22, 10, 0, 0, 0, time.UTC) })
		marketDataContract(t, client)
	})
}
