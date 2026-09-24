package betfair

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/httpx"
	"github.com/bensuskins/races/server/internal/matching"
)

const (
	// RequestsPerSecond is conservative: one refresh fans out into many calls.
	RequestsPerSecond = 5.0
	// MaxMarketsPerBook is a hard cap, not a guideline.
	MaxMarketsPerBook    = 40
	horseRacingEventType = "7"
)

// Client is the read-only betting API.
type Client struct {
	Session *Session
	creds   Credentials
	http    *httpx.Client
	now     func() time.Time
}

// New builds a client and its session from one set of credentials. identity
// and betting are the two base URLs; tests point both at one fake.
func New(creds Credentials, identity, betting *httpx.Client, now func() time.Time) *Client {
	if now == nil {
		now = time.Now
	}
	if identity == nil {
		identity = httpx.New(IdentityBaseURL, 1, nil)
	}
	if betting == nil {
		betting = httpx.New(BettingBaseURL, RequestsPerSecond, nil)
	}
	return &Client{Session: NewSession(creds, identity, now), creds: creds, http: betting, now: now}
}

// HTTP exposes the betting pipeline for payload recording.
func (c *Client) HTTP() *httpx.Client { return c.http }

// Markets are one London day's GB and IE win markets, with the runner metadata
// the matcher joins on.
func (c *Client) Markets(ctx context.Context, day string, countries ...string) ([]matching.ExchangeMarket, error) {
	if len(countries) == 0 {
		countries = []string{"GB", "IE"}
	}
	start, end, ok := domain.DayWindow(day)
	if !ok {
		return nil, &httpx.Error{Kind: httpx.BadRequest, Message: "bad day " + day}
	}
	request := map[string]any{
		"filter": map[string]any{
			"eventTypeIds":    []string{horseRacingEventType},
			"marketCountries": countries,
			"marketTypeCodes": []string{"WIN"},
			"marketStartTime": map[string]string{
				"from": start.UTC().Format(time.RFC3339),
				"to":   end.UTC().Format(time.RFC3339),
			},
		},
		// RUNNER_METADATA carries CLOTH_NUMBER.
		"marketProjection": []string{"RUNNER_METADATA", "MARKET_START_TIME", "EVENT"},
		"maxResults":       200,
		"sort":             "FIRST_TO_START",
	}
	var catalogues []catalogueDTO
	if err := c.send(ctx, "/listMarketCatalogue/", request, &catalogues); err != nil {
		return nil, err
	}
	var out []matching.ExchangeMarket
	for _, cat := range catalogues {
		if m, ok := mapMarket(cat); ok {
			out = append(out, m)
		}
	}
	return out, nil
}

// Prices are best offers for the given markets.
func (c *Client) Prices(ctx context.Context, marketIDs []string) ([]matching.ExchangePrices, error) {
	books, err := c.books(ctx, marketIDs, []string{"EX_BEST_OFFERS"})
	if err != nil {
		return nil, err
	}
	var out []matching.ExchangePrices
	for _, b := range books {
		if p, ok := mapPrices(b, c.now()); ok {
			out = append(out, p)
		}
	}
	return out, nil
}

// StartingPrices are [marketID][selectionID] actual SPs for settled markets.
// An absent or zero SP is omitted: a zero would wreck the ROI figure.
func (c *Client) StartingPrices(ctx context.Context, marketIDs []string) (map[string]map[int64]float64, error) {
	books, err := c.books(ctx, marketIDs, []string{"SP_TRADED"})
	if err != nil {
		return nil, err
	}
	out := map[string]map[int64]float64{}
	for _, b := range books {
		settled := map[int64]float64{}
		for _, r := range b.Runners {
			if r.SP != nil && r.SP.ActualSP != nil && *r.SP.ActualSP > 0 {
				settled[r.SelectionID] = *r.SP.ActualSP
			}
		}
		if len(settled) > 0 {
			out[b.MarketID] = settled
		}
	}
	return out, nil
}

func (c *Client) books(ctx context.Context, marketIDs []string, priceData []string) ([]bookDTO, error) {
	set := map[string]bool{}
	for _, id := range marketIDs {
		set[id] = true
	}
	unique := make([]string, 0, len(set))
	for id := range set {
		unique = append(unique, id)
	}
	sort.Strings(unique)
	var out []bookDTO
	for i := 0; i < len(unique); i += MaxMarketsPerBook {
		batch := unique[i:min(i+MaxMarketsPerBook, len(unique))]
		books, err := c.booksSplitting(ctx, batch, priceData)
		if err != nil {
			return nil, err
		}
		out = append(out, books...)
	}
	return out, nil
}

// booksSplitting halves on TOO_MUCH_DATA: an instruction, not a failure.
func (c *Client) booksSplitting(ctx context.Context, ids []string, priceData []string) ([]bookDTO, error) {
	var books []bookDTO
	err := c.send(ctx, "/listMarketBook/", map[string]any{
		"marketIds":       ids,
		"priceProjection": map[string]any{"priceData": priceData, "virtualise": false},
	}, &books)
	var f *Fault
	if errors.As(err, &f) && f.Code == "TOO_MUCH_DATA" && len(ids) > 1 {
		mid := len(ids) / 2
		left, err := c.booksSplitting(ctx, ids[:mid], priceData)
		if err != nil {
			return nil, err
		}
		right, err := c.booksSplitting(ctx, ids[mid:], priceData)
		if err != nil {
			return nil, err
		}
		return append(left, right...), nil
	}
	if f != nil {
		return nil, f.AsError()
	}
	return books, err
}

// send makes one authenticated call, re-authenticating exactly once if the
// session has lapsed. TOO_MUCH_DATA comes back as a *Fault for the caller.
func (c *Client) send(ctx context.Context, path string, body any, out any) error {
	err := c.sendOnce(ctx, path, body, out)
	var f *Fault
	if !errors.As(err, &f) {
		return err
	}
	if f.Code == "TOO_MUCH_DATA" {
		return f
	}
	if !f.InvalidSession() {
		return f.AsError()
	}
	c.Session.Invalidate()
	err = c.sendOnce(ctx, path, body, out)
	if errors.As(err, &f) {
		if f.Code == "TOO_MUCH_DATA" {
			return f
		}
		return f.AsError()
	}
	return err
}

func (c *Client) sendOnce(ctx context.Context, path string, body any, out any) error {
	token, err := c.Session.Token(ctx)
	if err != nil {
		return err
	}
	resp, err := c.http.PostJSON(ctx, path, body, httpx.Headers(map[string]string{
		"X-Application": c.creds.AppKey, "X-Authentication": token, "Accept": "application/json",
	}))
	// A fault arrives on a 200 as readily as a 400: read the body either way.
	if fault := decodeFault(resp.Body); fault != nil {
		return fault
	}
	if err != nil {
		return err
	}
	return resp.Decode(out)
}

// decodeFault reads the APINGException envelope, or nil if the body is not one.
func decodeFault(body []byte) *Fault {
	trimmed := strings.TrimSpace(string(body))
	if !strings.HasPrefix(trimmed, "{") {
		return nil
	}
	var env struct {
		FaultString *string `json:"faultstring"`
		Detail      *struct {
			APING *struct {
				ErrorCode    *string `json:"errorCode"`
				ErrorDetails *string `json:"errorDetails"`
			} `json:"APINGException"`
		} `json:"detail"`
	}
	if json.Unmarshal(body, &env) != nil {
		return nil
	}
	code, details := "", ""
	if env.Detail != nil && env.Detail.APING != nil {
		code, details = deref(env.Detail.APING.ErrorCode), deref(env.Detail.APING.ErrorDetails)
	}
	if code == "" {
		code = deref(env.FaultString)
	}
	if code == "" {
		return nil
	}
	return &Fault{Code: code, Details: details}
}

// MARK: - Wire types

type metadata map[string]*string

// UnmarshalJSON tolerates numeric, boolean and null metadata values: the docs
// say strings, the live feed disagrees, and one odd value must not invalidate
// a catalogue.
func (m *metadata) UnmarshalJSON(data []byte) error {
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*m = metadata{}
	for k, v := range raw {
		var s string
		switch t := v.(type) {
		case string:
			s = t
		case float64:
			s = strconv.FormatFloat(t, 'f', -1, 64)
		case bool:
			s = strconv.FormatBool(t)
		default:
			continue
		}
		(*m)[k] = &s
	}
	return nil
}

type catalogueDTO struct {
	MarketID        string  `json:"marketId"`
	MarketName      *string `json:"marketName"`
	MarketStartTime *string `json:"marketStartTime"`
	Event           *struct {
		Name  *string `json:"name"`
		Venue *string `json:"venue"`
	} `json:"event"`
	Runners []struct {
		SelectionID int64    `json:"selectionId"`
		RunnerName  *string  `json:"runnerName"`
		Status      *string  `json:"status"`
		Metadata    metadata `json:"metadata"`
	} `json:"runners"`
}

type bookDTO struct {
	MarketID            string `json:"marketId"`
	Status              string `json:"status"`
	IsMarketDataDelayed *bool  `json:"isMarketDataDelayed"`
	Runners             []struct {
		SelectionID     int64    `json:"selectionId"`
		Status          *string  `json:"status"`
		LastPriceTraded *float64 `json:"lastPriceTraded"`
		Ex              *struct {
			AvailableToBack []struct {
				Price *float64 `json:"price"`
			} `json:"availableToBack"`
			AvailableToLay []struct {
				Price *float64 `json:"price"`
			} `json:"availableToLay"`
		} `json:"ex"`
		SP *struct {
			NearPrice *float64 `json:"nearPrice"`
			ActualSP  *float64 `json:"actualSP"`
		} `json:"sp"`
	} `json:"runners"`
}

// MARK: - Mapping

func mapMarket(c catalogueDTO) (matching.ExchangeMarket, bool) {
	// No start time means no window, and a market matched on venue alone would
	// price a race off whatever else runs at that course.
	if c.MarketStartTime == nil {
		return matching.ExchangeMarket{}, false
	}
	start, ok := domain.ParseTimestamp(*c.MarketStartTime)
	if !ok || c.Event == nil {
		return matching.ExchangeMarket{}, false
	}
	venue := deref(c.Event.Venue)
	if venue == "" {
		venue = deref(c.Event.Name)
	}
	if venue == "" {
		return matching.ExchangeMarket{}, false
	}
	m := matching.ExchangeMarket{ID: c.MarketID, Venue: venue, StartTime: start, MarketName: deref(c.MarketName)}
	for _, r := range c.Runners {
		m.Runners = append(m.Runners, matching.ExchangeRunner{
			ID: r.SelectionID, Name: deref(r.RunnerName), ClothNumber: ClothNumber(r.Metadata),
			IsActive: r.Status == nil || *r.Status == "ACTIVE",
		})
	}
	return m, true
}

// ClothNumber requires > 0: "0" means "not published", and treating it as real
// would join on a value every such runner shares.
func ClothNumber(m map[string]*string) *int {
	raw, ok := m["CLOTH_NUMBER"]
	if !ok || raw == nil {
		return nil
	}
	v, err := strconv.Atoi(strings.TrimSpace(*raw))
	if err != nil || v <= 0 {
		return nil
	}
	return &v
}

func mapPrices(b bookDTO, captured time.Time) (matching.ExchangePrices, bool) {
	prices := map[int64]domain.RunnerPrice{}
	for _, r := range b.Runners {
		p := domain.RunnerPrice{LastTraded: r.LastPriceTraded, IsActive: r.Status == nil || *r.Status == "ACTIVE"}
		// The ladder is best-price-first, so the best is .first, never max.
		if r.Ex != nil {
			if len(r.Ex.AvailableToBack) > 0 {
				p.BackPrice = r.Ex.AvailableToBack[0].Price
			}
			if len(r.Ex.AvailableToLay) > 0 {
				p.LayPrice = r.Ex.AvailableToLay[0].Price
			}
		}
		if r.SP != nil {
			p.ForecastPrice = r.SP.NearPrice
		}
		prices[r.SelectionID] = p
	}
	if len(prices) == 0 {
		return matching.ExchangePrices{}, false
	}
	delayed := true // the free key is always delayed; absent means assume so
	if b.IsMarketDataDelayed != nil {
		delayed = *b.IsMarketDataDelayed
	}
	return matching.ExchangePrices{MarketID: b.MarketID, Status: b.Status, CapturedAt: captured, IsDelayed: delayed, Prices: prices}, true
}
