package service

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/backtest"
	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/matching"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/store"
	"github.com/bensuskins/races/server/internal/tracking"
)

// The card: two races at Ascot today, 14:30 and 15:05 London.
var day = time.Date(2026, 9, 20, 0, 0, 0, 0, domain.London)

func ip(v int) *int         { return &v }
func fp(v float64) *float64 { return &v }
func sp(v string) *string   { return &v }

func testRace(id string, off time.Time, names ...string) domain.Race {
	r := domain.Race{ID: id, CourseName: "Ascot", Name: "Test Handicap", OffTime: off.In(domain.London).Format("15:04"),
		OffDateTime: domain.Ptr(off), Date: "2026-09-20", Type: domain.RaceTypeFlat, Going: domain.GoingGood, Surface: domain.SurfaceTurf}
	for i, n := range names {
		r.Runners = append(r.Runners, domain.Runner{ID: id + "_" + n, Name: n, ClothNumber: ip(i + 1), OfficialRating: ip(90 - i*3), Form: sp("1-2" + string(rune('1'+i)))})
	}
	return r
}

type fakeRacing struct {
	cards   []domain.Race
	results []domain.RaceResult
	err     error
}

func (f *fakeRacing) Courses(ctx context.Context, regions ...string) ([]domain.Course, error) {
	return []domain.Course{{ID: "crs_1", Name: "Ascot", RegionCode: "gb"}}, nil
}
func (f *fakeRacing) Racecards(ctx context.Context, day domain.RaceDay, regions ...string) ([]domain.Race, error) {
	if day == domain.Tomorrow {
		return nil, nil
	}
	return f.cards, f.err
}
func (f *fakeRacing) TodaysResults(ctx context.Context) ([]domain.RaceResult, error) {
	return f.results, f.err
}

type fakeMarkets struct {
	markets    []matching.ExchangeMarket
	prices     map[string]map[int64]float64
	sps        map[string]map[int64]float64
	spErr      error
	priceHit   int
	capturedAt *time.Time
}

func (f *fakeMarkets) Markets(ctx context.Context, day string, c ...string) ([]matching.ExchangeMarket, error) {
	return f.markets, nil
}
func (f *fakeMarkets) Prices(ctx context.Context, ids []string) ([]matching.ExchangePrices, error) {
	f.priceHit++
	var out []matching.ExchangePrices
	for _, id := range ids {
		capturedAt := time.Now()
		if f.capturedAt != nil {
			capturedAt = *f.capturedAt
		}
		p := matching.ExchangePrices{MarketID: id, IsDelayed: true, CapturedAt: capturedAt, Prices: map[int64]domain.RunnerPrice{}}
		for sel, back := range f.prices[id] {
			p.Prices[sel] = domain.RunnerPrice{BackPrice: fp(back), IsActive: true}
		}
		out = append(out, p)
	}
	return out, nil
}
func (f *fakeMarkets) StartingPrices(ctx context.Context, ids []string) (map[string]map[int64]float64, error) {
	return f.sps, f.spErr
}

func market(id string, r domain.Race) matching.ExchangeMarket {
	m := matching.ExchangeMarket{ID: id, Venue: "Ascot", StartTime: r.OffDateTime.Time}
	for i, run := range r.Runners {
		m.Runners = append(m.Runners, matching.ExchangeRunner{ID: int64(100*len(id) + i + 1), Name: run.Name, ClothNumber: ip(i + 1), IsActive: true})
	}
	return m
}

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func setup(t *testing.T) (*Service, *fakeRacing, *fakeMarkets, *clock, domain.Race, domain.Race) {
	t.Helper()
	st, err := store.Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	first := testRace("rac_1", day.Add(14*time.Hour+30*time.Minute), "Alpha", "Bravo", "Charlie", "Delta")
	second := testRace("rac_2", day.Add(15*time.Hour+5*time.Minute), "Echo", "Foxtrot", "Golf")
	racing := &fakeRacing{cards: []domain.Race{first, second}}
	m1, m2 := market("1.1", first), market("1.22", second)
	markets := &fakeMarkets{markets: []matching.ExchangeMarket{m1, m2}, prices: map[string]map[int64]float64{
		"1.1": {m1.Runners[0].ID: 2.5, m1.Runners[1].ID: 3.5, m1.Runners[2].ID: 6, m1.Runners[3].ID: 11},
		// The second market has no money in it at all.
		"1.22": {},
	}}
	c := &clock{t: day.Add(9 * time.Hour)}
	s := New(st, racing, markets, c.now, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := s.Bootstrap(context.Background()); err != nil {
		t.Fatal(err)
	}
	return s, racing, markets, c, first, second
}

func TestADayEndToEnd(t *testing.T) {
	ctx := context.Background()
	s, racing, markets, c, first, second := setup(t)
	s.Execute(ctx, Everything)

	// Morning: both races drafted, neither sealed.
	row, _ := s.Store.Tip(ctx, "rac_1")
	if row == nil || row.Tip.IsSealed() || row.Tip.WasFormOnly {
		t.Fatalf("race 1 should be a priced draft: %+v", row)
	}
	row2, _ := s.Store.Tip(ctx, "rac_2")
	if row2 == nil || !row2.Tip.WasFormOnly || row2.Tip.MarketReference == nil {
		t.Fatal("a matched market with no prices is form-only but keeps its reference for SP")
	}

	// Three minutes before the first off: sealed, with a seal snapshot and a
	// training snapshot.
	c.t = first.OffDateTime.Add(-3 * time.Minute)
	s.Execute(ctx, PlanFor(c.t))
	row, _ = s.Store.Tip(ctx, "rac_1")
	if !row.Tip.IsSealed() || row.Source != "server" {
		t.Fatal("inside the window the tip is sealed")
	}
	sealedAt := row.Tip.SealedAt.Time
	if snap, _ := s.Store.LatestSnapshot(ctx, "rac_1", "seal"); snap == nil {
		t.Fatal("the prices it was sealed on are kept")
	}
	if _, pending := s.Store.TrainingCounts(ctx); pending != 1 {
		t.Fatal("a training snapshot is frozen at the seal")
	}
	c.t = c.t.Add(time.Minute)
	s.Execute(ctx, PlanFor(c.t))
	if row, _ = s.Store.Tip(ctx, "rac_1"); !row.Tip.SealedAt.Time.Equal(sealedAt) {
		t.Fatal("a sealed tip is never rewritten")
	}

	// After both have run: results arrive and settle with Betfair SP.
	sel := row.Tip.SelectionHorseID
	selID := row.Tip.MarketReference.SelectionIDsByHorseID[sel]
	racing.results = []domain.RaceResult{result(first, sel), result(second, second.Runners[0].ID)}
	markets.sps = map[string]map[int64]float64{"1.1": {selID: 3.1}}
	c.t = second.OffDateTime.Add(time.Hour)
	ing, err := s.CollectResults(ctx)
	if err != nil {
		t.Fatal(err)
	}
	row, _ = s.Store.Tip(ctx, "rac_1")
	if row.Tip.Outcome == nil || row.Tip.Outcome.Kind != tracking.Won || *row.Tip.Outcome.BetfairSP != 3.1 {
		t.Fatalf("settled won at BSP: %+v", row.Tip.Outcome)
	}
	if ing.SamplesSettled != 1 || ing.RacesArchived != 2 {
		t.Fatalf("%+v", ing)
	}
	// Race 2 was never inside the seal window while the server looked, so its
	// draft is settled as it stands — exactly what the device ledger did.
	if row2, _ = s.Store.Tip(ctx, "rac_2"); row2.Tip.Outcome == nil {
		t.Fatal("race 2 settled")
	}

	// Idempotent: a second pass archives nothing new.
	if ing, _ = s.CollectResults(ctx); ing.RacesArchived != 0 || ing.TipsSettled != 0 {
		t.Fatalf("%+v", ing)
	}

	// The sealed race replays through any weights, against the market.
	beforeChange, err := backtest.Run(ctx, s.Store, rating.V2(), backtest.Request{From: "2026-09-20", To: "2026-09-20"})
	if err != nil {
		t.Fatal(err)
	}
	changed := first
	changed.Name = "Updated after sealing"
	changed.Runners = changed.Runners[:1]
	if err := s.Store.SaveRaces(ctx, []domain.Race{changed}, c.t.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	for _, w := range []rating.Weights{rating.V2(), rating.MarketOnly()} {
		rep, err := backtest.Run(ctx, s.Store, w, backtest.Request{From: "2026-09-20", To: "2026-09-20"})
		if err != nil || rep.Rerated.Races != 1 || rep.HighestProbability.Races != rep.ValueSelection.Races || rep.CorpusID == "" || rep.Snapshots != 1 || rep.Rerated.LogLoss == nil || rep.MarketLogLoss == nil || rep.BeatsMarket == nil {
			t.Fatalf("%s: %+v %v", w.ID, rep, err)
		}
		if w.ID == "market-only" && math.Abs(*rep.Rerated.LogLoss-*rep.MarketLogLoss) > 1e-9 {
			t.Fatal("the control arm is the market exactly")
		}
		if w.ID == "v2" && (rep.HighestProbability.Wins != beforeChange.HighestProbability.Wins ||
			*rep.HighestProbability.StrikeRate != *beforeChange.HighestProbability.StrikeRate) {
			t.Fatal("a later card refresh changed the sealed replay")
		}
	}
	if rep, _ := backtest.Run(ctx, s.Store, rating.V2(), backtest.Request{From: "2026-09-21"}); rep.Rerated.Races != 0 {
		t.Fatal("the date range is applied")
	}
}

func TestMarketMovementFreezesFirstObservedPricesAtSeal(t *testing.T) {
	ctx := context.Background()
	s, _, markets, _, race, _ := setup(t)
	if err := s.Store.SaveRaces(ctx, []domain.Race{race}, race.OffDateTime.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := s.RefreshMarkets(ctx, domain.Today); err != nil {
		t.Fatal(err)
	}
	openingAt := race.OffDateTime.Add(-30 * time.Minute)
	markets.capturedAt = &openingAt
	selectionID := markets.markets[0].Runners[0].ID
	if _, err := s.rateAndRecord(ctx, []domain.Race{race}, "display", openingAt); err != nil {
		t.Fatal(err)
	}
	markets.prices["1.1"][selectionID] = 2.0
	latestAt := race.OffDateTime.Add(-10 * time.Minute)
	markets.capturedAt = &latestAt
	if _, err := s.rateAndRecord(ctx, []domain.Race{race}, "display", latestAt); err != nil {
		t.Fatal(err)
	}
	assessment, err := s.Store.Assessment(ctx, race.ID)
	if err != nil || assessment == nil {
		t.Fatalf("latest assessment missing: %v", err)
	}
	var movement *rating.Contribution
	for _, runner := range assessment.Runners {
		if runner.HorseID != race.Runners[0].ID {
			continue
		}
		for index := range runner.Contributions {
			if runner.Contributions[index].Factor == rating.MarketMovement {
				movement = &runner.Contributions[index]
			}
		}
	}
	if movement == nil || movement.Availability.Kind != rating.Available || !strings.Contains(movement.Detail, "+10.0") {
		t.Fatalf("market movement was not available before seal: %+v", movement)
	}
	sealAt := race.OffDateTime.Add(-3 * time.Minute)
	markets.prices["1.1"][selectionID] = 1.67
	markets.capturedAt = &sealAt
	if _, err := s.rateAndRecord(ctx, []domain.Race{race}, "seal", sealAt); err != nil {
		t.Fatal(err)
	}
	sealed, err := s.Store.LatestSnapshot(ctx, race.ID, "seal")
	if err != nil || sealed == nil || sealed.FirstObservedAt == nil || !sealed.FirstObservedAt.Equal(openingAt) || *sealed.FirstObservedPrices[race.Runners[0].ID].BackPrice != 2.5 {
		t.Fatalf("seal snapshot did not freeze the first observed prices: %+v, %v", sealed, err)
	}
}

func result(r domain.Race, winner string) domain.RaceResult {
	res := domain.RaceResult{ID: r.ID, CourseName: r.CourseName, Name: r.Name, Date: r.Date}
	pos := 2
	for _, run := range r.Runners {
		p := pos
		if run.ID == winner {
			p = 1
		} else {
			pos++
		}
		res.Finishers = append(res.Finishers, domain.Finisher{HorseID: run.ID, HorseName: run.Name, Position: domain.Finished(p), JockeyID: sp("jky_" + run.Name)})
	}
	return res
}

func TestRaceFirstSeenAfterTheOffIsNeverRecorded(t *testing.T) {
	ctx := context.Background()
	s, _, _, c, first, _ := setup(t)
	c.t = first.OffDateTime.Add(time.Minute)
	s.Execute(ctx, Everything)
	if row, _ := s.Store.Tip(ctx, "rac_1"); row != nil {
		t.Fatal("a race opened after it has run never enters the tracker")
	}
}

func TestStartingPriceFailureCostsOnlyROI(t *testing.T) {
	ctx := context.Background()
	s, racing, markets, c, first, _ := setup(t)
	c.t = first.OffDateTime.Add(-2 * time.Minute)
	s.Execute(ctx, Everything)
	row, _ := s.Store.Tip(ctx, "rac_1")
	racing.results = []domain.RaceResult{result(first, row.Tip.SelectionHorseID)}
	markets.spErr = errors.New("betfair down")
	c.t = first.OffDateTime.Add(time.Hour)
	ing, err := s.CollectResults(ctx)
	if err != nil || !ing.PricesFailed {
		t.Fatal(err)
	}
	row, _ = s.Store.Tip(ctx, "rac_1")
	if row.Tip.Outcome.Kind != tracking.Won || row.Tip.Outcome.BetfairSP != nil {
		t.Fatal("settled on the result alone")
	}
}

func TestWithoutBetfairEverythingIsFormOnly(t *testing.T) {
	ctx := context.Background()
	s, _, _, _, _, _ := setup(t)
	s.Markets = nil
	s.Execute(ctx, Everything)
	row, _ := s.Store.Tip(ctx, "rac_1")
	if row == nil || !row.Tip.WasFormOnly || row.Tip.MarketReference != nil {
		t.Fatal("no Betfair is an ordinary state")
	}
}

func TestPlanTimetable(t *testing.T) {
	at := func(h, m int) Plan {
		return PlanFor(day.Add(time.Duration(h)*time.Hour + time.Duration(m)*time.Minute))
	}
	if p := at(10, 15); !p.CardsToday || !p.DraftToday || p.CardsTomorrow || p.Results || !p.Seal {
		t.Fatalf("%+v", p)
	}
	if p := at(13, 0); !p.CardsTomorrow || !p.Results {
		t.Fatalf("%+v", p)
	}
	if p := at(23, 55); !p.Results || p.CardsToday {
		t.Fatal("the last results pass of the day")
	}
	if p := at(3, 0); !p.Train || p.CardsToday {
		t.Fatal("nightly training")
	}
	if p := at(2, 45); !p.Backtest || p.Train {
		t.Fatal("nightly baseline replay precedes training")
	}
	if p := at(10, 7); p.CardsToday || !p.Seal {
		t.Fatal("seal every minute, cards every quarter")
	}
}

func TestBaselineBacktestStoresReportAndStatus(t *testing.T) {
	ctx := context.Background()
	s, _, _, _, _, _ := setup(t)
	reportID, report, err := s.BaselineBacktest(ctx)
	if err != nil || reportID == 0 || report.WeightsID != "v3" {
		t.Fatalf("baseline report was not stored: %d %+v %v", reportID, report, err)
	}
	runs, err := s.Store.JobRuns(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, run := range runs {
		if run.Name == "baseline-backtest" && run.SucceededAt != nil && strings.Contains(run.Summary, "report 1") {
			return
		}
	}
	t.Fatalf("baseline result is absent from status: %+v", runs)
}

// A server that was running v2 moves onto v3 at boot, because v2 was only ever
// the default; a trained set was promoted on evidence and stays.
func TestBootstrapMovesV2OntoV3AndLeavesTrainedSetsAlone(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	s := New(st, &fakeRacing{}, nil, time.Now, slog.New(slog.NewTextHandler(io.Discard, nil)))

	if err := s.Bootstrap(ctx); err != nil {
		t.Fatal(err)
	}
	if w, _ := st.ActiveWeights(ctx); w == nil || w.ID != "v3" {
		t.Fatal("a fresh database runs v3", w)
	}

	st.SetActiveWeights(ctx, "v2")
	if err := s.Bootstrap(ctx); err != nil {
		t.Fatal(err)
	}
	if w, _ := st.ActiveWeights(ctx); w == nil || w.ID != "v3" || !w.PicksMostLikelyWinner() {
		t.Fatal("v2 moves onto v3", w)
	}

	learned := rating.V2().Clone()
	learned.ID = "learned-1-150"
	st.EnsureWeights(ctx, learned, "trained", time.Now())
	st.SetActiveWeights(ctx, learned.ID)
	if err := s.Bootstrap(ctx); err != nil {
		t.Fatal(err)
	}
	if w, _ := st.ActiveWeights(ctx); w == nil || w.ID != learned.ID {
		t.Fatal("a trained set stays active", w)
	}
}
