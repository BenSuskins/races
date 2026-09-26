package rating

import (
	"math"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
)

func ip(v int) *int               { return &v }
func sp(v string) *string         { return &v }
func fp(v float64) *float64       { return &v }
func near(a, b, tol float64) bool { return math.Abs(a-b) <= tol }

type runnerOpts struct {
	number, draw, age, or, weight, days *int
	form, headgear, jockey, trainer     *string
}

// runner mirrors TestRace.runner: age 5, 133 lb and 21 days unless overridden.
func runner(id string, o runnerOpts) domain.Runner {
	if o.age == nil {
		o.age = ip(5)
	}
	if o.weight == nil {
		o.weight = ip(133)
	}
	if o.days == nil {
		o.days = ip(21)
	}
	return domain.Runner{
		ID: id, Name: id, ClothNumber: o.number, Draw: o.draw, Age: o.age, OfficialRating: o.or,
		WeightPounds: o.weight, Headgear: o.headgear, Form: o.form, DaysSinceLastRun: o.days,
		JockeyID: o.jockey, TrainerID: o.trainer,
	}
}

func race(name string, typ domain.RaceType, band *domain.ClosedRange, ageBand *string, runners ...domain.Runner) domain.Race {
	return domain.Race{
		ID: "rac_test", CourseName: "Ascot", Name: name, OffTime: "14:30", Date: "2026-09-20",
		Distance: &domain.Distance{Furlongs: 8}, Going: domain.GoingGood, Surface: domain.SurfaceTurf,
		Type: typ, RaceClass: ip(3), AgeBand: ageBand, RatingBand: band, FieldSize: ip(len(runners)),
		Runners: runners,
	}
}

func market(prices map[string]float64) *domain.MarketSnapshot {
	m := &domain.MarketSnapshot{MarketID: sp("1.234"), Source: domain.SourceLiveExchange, IsDelayed: true, Prices: map[string]domain.RunnerPrice{}}
	for id, p := range prices {
		m.Prices[id] = domain.RunnerPrice{BackPrice: fp(p), IsActive: true}
	}
	return m
}

func fourRunnerHandicap() domain.Race {
	return race("Ascot Handicap", domain.RaceTypeFlat, &domain.ClosedRange{Lower: 0, Upper: 95}, sp("3yo+"),
		runner("a", runnerOpts{number: ip(1), draw: ip(1), or: ip(95), form: sp("1-3241"), days: ip(21)}),
		runner("b", runnerOpts{number: ip(2), draw: ip(2), or: ip(88), form: sp("21-113"), days: ip(14)}),
		runner("c", runnerOpts{number: ip(3), draw: ip(3), or: ip(80), form: sp("0-450"), days: ip(60)}),
		runner("d", runnerOpts{number: ip(4), draw: ip(4), or: ip(72), form: sp("P0-08"), days: ip(200)}),
	)
}

func fullMarket() *domain.MarketSnapshot {
	return market(map[string]float64{"a": 1.7, "b": 3.4, "c": 8.5, "d": 19.0})
}

var epoch = time.Unix(0, 0)

type fakeStrikeRates struct {
	jockeys, trainers                 map[string]StrikeRate
	jockeySurfaces, trainerSurfaces   map[string]StrikeRate
	jockeyRaceTypes, trainerRaceTypes map[string]StrikeRate
	jockeyGoings, trainerGoings       map[string]StrikeRate
	jockeyRecent, trainerRecent       map[string]StrikeRate
	jockeyTrainer                     map[string]StrikeRate
	drawBiasRecord                    DrawBiasRate
	drawBiasExists                    bool
	horseClassRate                    ClassAdjustedFormRate
	horseClassExists                  bool
	horseGoings                       map[string]PlaceRate
	horseOverall                      map[string]PlaceRate
	baseline                          float64
}

func (f fakeStrikeRates) JockeyStrikeRate(id string) (StrikeRate, bool) {
	s, ok := f.jockeys[id]
	return s, ok
}
func (f fakeStrikeRates) TrainerStrikeRate(id string) (StrikeRate, bool) {
	s, ok := f.trainers[id]
	return s, ok
}
func (f fakeStrikeRates) BaselineStrikeRate() float64 { return f.baseline }
func (f fakeStrikeRates) JockeyRecentStrikeRate(id string) (StrikeRate, bool) {
	rate, ok := f.jockeyRecent[id]
	return rate, ok
}
func (f fakeStrikeRates) TrainerRecentStrikeRate(id string) (StrikeRate, bool) {
	rate, ok := f.trainerRecent[id]
	return rate, ok
}
func (f fakeStrikeRates) JockeyTrainerStrikeRate(jockeyID, trainerID string) (StrikeRate, bool) {
	rate, ok := f.jockeyTrainer[jockeyID+"|"+trainerID]
	return rate, ok
}
func (f fakeStrikeRates) DrawBiasRate(domain.Race, domain.Runner) (DrawBiasRate, bool) {
	return f.drawBiasRecord, f.drawBiasExists
}
func (f fakeStrikeRates) HorseClassFormRate(string, int) (ClassAdjustedFormRate, bool) {
	return f.horseClassRate, f.horseClassExists
}
func (f fakeStrikeRates) JockeySurfaceStrikeRate(id string, surface domain.Surface) (StrikeRate, bool) {
	rate, ok := f.jockeySurfaces[id+"|"+string(surface)]
	return rate, ok
}
func (f fakeStrikeRates) TrainerSurfaceStrikeRate(id string, surface domain.Surface) (StrikeRate, bool) {
	rate, ok := f.trainerSurfaces[id+"|"+string(surface)]
	return rate, ok
}
func (f fakeStrikeRates) JockeyRaceTypeStrikeRate(id string, raceType domain.RaceType) (StrikeRate, bool) {
	rate, ok := f.jockeyRaceTypes[id+"|"+string(raceType)]
	return rate, ok
}
func (f fakeStrikeRates) TrainerRaceTypeStrikeRate(id string, raceType domain.RaceType) (StrikeRate, bool) {
	rate, ok := f.trainerRaceTypes[id+"|"+string(raceType)]
	return rate, ok
}
func (f fakeStrikeRates) JockeyGoingStrikeRate(id string, surface domain.Surface, bucket domain.GoingBucket) (StrikeRate, bool) {
	rate, ok := f.jockeyGoings[id+"|"+string(surface)+"|"+string(bucket)]
	return rate, ok
}
func (f fakeStrikeRates) TrainerGoingStrikeRate(id string, surface domain.Surface, bucket domain.GoingBucket) (StrikeRate, bool) {
	rate, ok := f.trainerGoings[id+"|"+string(surface)+"|"+string(bucket)]
	return rate, ok
}
func (f fakeStrikeRates) HorseGoingRate(horseID string, surface domain.Surface, bucket domain.GoingBucket) (PlaceRate, bool) {
	rate, ok := f.horseGoings[horseID+"|"+string(surface)+"|"+string(bucket)]
	return rate, ok
}
func (f fakeStrikeRates) HorseOverallPlaceRate(horseID string) (PlaceRate, bool) {
	rate, ok := f.horseOverall[horseID]
	return rate, ok
}

func contribution(t *testing.T, r RunnerAssessment, id FactorID) Contribution {
	t.Helper()
	for _, c := range r.Contributions {
		if c.Factor == id {
			return c
		}
	}
	t.Fatalf("no %s contribution", id)
	return Contribution{}
}

func runnerNamed(t *testing.T, a Assessment, id string) RunnerAssessment {
	t.Helper()
	for _, r := range a.Runners {
		if r.HorseID == id {
			return r
		}
	}
	t.Fatalf("no runner %s", id)
	return RunnerAssessment{}
}

// MARK: - Standardiser

func TestZScores(t *testing.T) {
	z := ZScores([]*float64{fp(1), fp(2), fp(3), fp(4), fp(5)}, 2.5)
	sum := 0.0
	for _, v := range z {
		sum += v
	}
	if !near(sum, 0, 1e-4) || z[4] <= z[0] {
		t.Fatal(z)
	}
	z = ZScores([]*float64{fp(10), nil, fp(50)}, 2.5)
	if z[1] != 0 || z[0] >= 0 || z[2] <= 0 {
		t.Fatal("unknown is average, not worst", z)
	}
	for _, same := range [][]*float64{{fp(7), fp(7), fp(7)}, {nil, nil}, {fp(5), nil, nil}} {
		for _, v := range ZScores(same, 2.5) {
			if v != 0 {
				t.Fatal("cannot discriminate → zero")
			}
		}
	}
	vals := []*float64{}
	for range 9 {
		vals = append(vals, fp(1))
	}
	vals = append(vals, fp(1000))
	if z := ZScores(vals, 2); !near(z[9], 2, 1e-4) {
		t.Fatal("clip", z[9])
	}
	if z := ZScores([]*float64{fp(1), fp(2), fp(math.NaN()), fp(3)}, 2.5); z[2] != 0 {
		t.Fatal("NaN is missing")
	}
}

// MARK: - Form

func TestMostRecentRunIsRightmost(t *testing.T) {
	line := ParseForm(sp("1-3241"))
	if won := line.WonLastTime(); won == nil || !*won {
		t.Fatal("the trailing 1 is the latest run")
	}
	if won := ParseForm(sp("123")).WonLastTime(); *won {
		t.Fatal("123 finished third last time")
	}
	if ParseForm(sp("0")).Outcomes[0].Position != 10 {
		t.Fatal("0 is tenth or worse")
	}
}

func TestFormParsingIsTotal(t *testing.T) {
	for _, raw := range []*string{nil, sp(""), sp("   ")} {
		if len(ParseForm(raw).runs()) != 0 {
			t.Fatal("empty")
		}
	}
	odd := ParseForm(sp("1X2"))
	if len(odd.runs()) != 2 {
		t.Fatal("X is not a run")
	}
	if r := ParseForm(sp("1-2/P")).CompletionRate(); !near(*r, 2.0/3.0, 1e-4) {
		t.Fatal(*r)
	}
	if r := ParseForm(sp("12PU")).CompletionRate(); !near(*r, 0.5, 1e-4) {
		t.Fatal(*r)
	}
}

func score(t *testing.T, form string) float64 {
	t.Helper()
	v := DefaultFormScorer().Score(ParseForm(&form))
	if v == nil {
		t.Fatalf("%s has no score", form)
	}
	return *v
}

func TestFormScorer(t *testing.T) {
	if DefaultFormScorer().Score(ParseForm(sp("-/"))) != nil {
		t.Fatal("gap markers alone are not runs")
	}
	if !near(score(t, "1"), 1, 1e-4) || !near(score(t, "PPP"), 0, 1e-4) {
		t.Fatal("range ends")
	}
	if !(score(t, "111") > score(t, "222") && score(t, "222") > score(t, "555") && score(t, "555") > score(t, "000") && score(t, "000") > score(t, "PPP")) {
		t.Fatal("better finishes score higher")
	}
	if score(t, "551") <= score(t, "155") {
		t.Fatal("recent runs count for more")
	}
	if !(score(t, "11/5") < score(t, "115") && score(t, "55/1") > score(t, "551")) {
		t.Fatal("a break discounts older runs")
	}
	if !(score(t, "11/5") < score(t, "11-5") && score(t, "55/1") > score(t, "55-1")) {
		t.Fatal("a long break discounts harder")
	}
	if !near(score(t, "11/1"), score(t, "111"), 1e-4) || !near(score(t, "1"), score(t, "111"), 1e-4) || !near(score(t, "1V1"), score(t, "11"), 1e-4) {
		t.Fatal("identity cases")
	}
	two := DefaultFormScorer()
	two.MaxRuns = 2
	if v := two.Score(ParseForm(sp("PPP11"))); !near(*v, 1, 1e-4) {
		t.Fatal("only the last two runs")
	}
}

// MARK: - Overround

func TestImpliedProbability(t *testing.T) {
	cases := []struct {
		p    RunnerPriceView
		want *float64
	}{
		{RunnerPriceView{Back: fp(2), Lay: fp(2.1), IsActive: true}, fp((0.5 + 1/2.1) / 2)},
		{RunnerPriceView{Back: fp(2), Lay: fp(10), IsActive: true}, fp(0.5)},
		{RunnerPriceView{LastTraded: fp(4), IsActive: true}, fp(0.25)},
		{RunnerPriceView{Forecast: fp(5), IsActive: true}, fp(0.2)},
		{RunnerPriceView{Back: fp(2), IsActive: false}, nil},
		{RunnerPriceView{IsActive: true}, nil},
		{RunnerPriceView{Back: fp(1), IsActive: true}, nil},
	}
	for i, c := range cases {
		got := ImpliedProbability(c.p)
		if (got == nil) != (c.want == nil) || (got != nil && !near(*got, *c.want, 1e-6)) {
			t.Fatalf("case %d: got %v", i, got)
		}
	}
}

func TestNormalise(t *testing.T) {
	sum := func(v []*float64) float64 { return BookSum(v) }
	if s := sum(Normalise([]*float64{fp(0.5), fp(0.35), fp(0.2)}, Proportional)); !near(s, 1, 1e-6) {
		t.Fatal(s)
	}
	n := Normalise([]*float64{fp(0.5), nil, fp(0.4)}, Proportional)
	if n[1] != nil {
		t.Fatal("unpriced stays unpriced")
	}
	if s := sum(Normalise([]*float64{fp(0.5), fp(0.35), fp(0.2), fp(0.1)}, Power)); !near(s, 1, 1e-6) {
		t.Fatal(s)
	}
	k := PowerExponent([]float64{0.5, 0.3, 0.15, 0.1})
	if k <= 1 {
		t.Fatal("an overround book needs an exponent above 1")
	}
	if PowerExponent([]float64{0.1, 0.1}) != 1 {
		t.Fatal("unsolvable falls back to 1")
	}
	if !near(BookSum([]*float64{fp(0.5), fp(0.35), fp(0.18)}), 1.03, 1e-6) {
		t.Fatal("book sum")
	}
}

// MARK: - Factors

func TestFactorReadings(t *testing.T) {
	ctx := Context{Race: race("Test Stakes", domain.RaceTypeFlat, nil, sp("3yo+"))}
	hcap := Context{Race: race("Ascot Handicap", domain.RaceTypeFlat, &domain.ClosedRange{Lower: 0, Upper: 95}, sp("3yo+"))}
	chase := Context{Race: race("Test Stakes", domain.RaceTypeChase, nil, sp("3yo+"))}

	if v := (officialRating{}).Value(runner("a", runnerOpts{or: ip(82)}), ctx); *v.Raw != 82 || v.Display != "OR 82" {
		t.Fatal("OR")
	}
	if v := (officialRating{}).Value(runner("a", runnerOpts{}), ctx); v.Availability != (Availability{MissingData, "no official rating"}) {
		t.Fatal("unrated")
	}
	if v := (handicapBandPosition{}).Value(runner("a", runnerOpts{or: ip(95)}), hcap); !near(*v.Raw, 1, 1e-4) || v.Display != "100% up the 0-95 band" {
		t.Fatal(v.Display)
	}
	if v := (handicapBandPosition{}).Value(runner("a", runnerOpts{or: ip(95)}), ctx); v.Availability.Reason != "not a handicap" {
		t.Fatal("not a handicap")
	}
	if v := (completionRate{}).Value(runner("a", runnerOpts{form: sp("12PU")}), chase); *v.Raw != 0.5 || v.Display != "Completed 50% of recent runs" {
		t.Fatal("completion over fences")
	}
	if v := (completionRate{}).Value(runner("a", runnerOpts{form: sp("12PU")}), ctx); v.Availability.Kind != NotApplicable {
		t.Fatal("flat")
	}
	if Freshness(21) != 1 || Freshness(3) >= 1 || Freshness(45) <= Freshness(150) || Freshness(-5) <= 0 {
		t.Fatal("freshness bell")
	}
	flat8 := (age{}).Value(runner("a", runnerOpts{age: ip(8)}), ctx)
	jump8 := (age{}).Value(runner("a", runnerOpts{age: ip(8)}), chase)
	if *jump8.Raw <= *flat8.Raw {
		t.Fatal("an 8yo is prime over fences")
	}
	if v := (age{}).Value(runner("a", runnerOpts{}), Context{Race: race("x", domain.RaceTypeFlat, nil, sp("3yo"))}); v.Availability.Kind != NotApplicable {
		t.Fatal("confined age")
	}
	if v := (weightCarried{}).Value(runner("a", runnerOpts{weight: ip(133)}), ctx); v.Display != "9-07" {
		t.Fatal(v.Display)
	}
	if v := (draw{}).Value(runner("a", runnerOpts{draw: ip(3)}), ctx); v.Raw != nil || v.Availability.Kind != MissingData {
		t.Fatal("draw without an archive must remain missing")
	}
	if v := (headgear{}).Value(runner("a", runnerOpts{headgear: sp("b")}), ctx); v.Display != "Wearing b" || v.Availability.Kind != RequiresPaidTier {
		t.Fatal("headgear")
	}
	thin := fakeStrikeRates{trainers: map[string]StrikeRate{"trn_1": {10, 4}}, baseline: 0.1}
	if v := (strikeRate{minimumSample: 30}).Value(runner("a", runnerOpts{trainer: sp("trn_1")}), Context{StrikeRates: thin}); v.Availability.Reason != "only 10 runs recorded so far" {
		t.Fatal(v.Availability.Reason)
	}
	solid := fakeStrikeRates{trainers: map[string]StrikeRate{"trn_1": {200, 40}}, baseline: 0.1}
	if v := (strikeRate{minimumSample: 30}).Value(runner("a", runnerOpts{trainer: sp("trn_1")}), Context{StrikeRates: solid}); !near(*v.Raw, 0.2, 0.02) || v.Display != "19% from 200 runs" {
		t.Fatal(v.Display)
	}
	if (StrikeRate{1, 1}).Smoothed(0.1, 20) >= 0.2 || (StrikeRate{400, 400}).Smoothed(0.1, 20) <= 0.9 {
		t.Fatal("shrinkage")
	}
}

// MARK: - Rater

func TestZeroFormInfluenceReproducesTheMarketExactly(t *testing.T) {
	a := NewRater(MarketOnly()).Rate(fourRunnerHandicap(), fullMarket(), nil, epoch)
	for _, r := range a.Runners {
		if !near(r.WinProbability, *r.MarketProbability, 1e-6) {
			t.Fatalf("%s: %f vs %f", r.HorseID, r.WinProbability, *r.MarketProbability)
		}
	}
}

func TestProbabilitiesSumToOneAndRankOrder(t *testing.T) {
	for _, m := range []*domain.MarketSnapshot{fullMarket(), nil} {
		a := NewRater(V2()).Rate(fourRunnerHandicap(), m, nil, epoch)
		total := 0.0
		for i, r := range a.Runners {
			total += r.WinProbability
			if r.WinProbability <= 0 || r.WinProbability >= 1 {
				t.Fatal("invalid probability")
			}
			if i > 0 && r.WinProbability > a.Runners[i-1].WinProbability {
				t.Fatal("rank order")
			}
		}
		if !near(total, 1, 1e-6) {
			t.Fatal(total)
		}
	}
}

func TestStaysAnchoredToTheMarket(t *testing.T) {
	a := NewRater(V1()).Rate(fourRunnerHandicap(), fullMarket(), nil, epoch)
	fav := runnerNamed(t, a, "a")
	if !near(fav.WinProbability, *fav.MarketProbability, 0.25) {
		t.Fatal("drifted from the market")
	}
}

func synthetic(formOnly bool, runners ...RunnerAssessment) Assessment {
	a := Assessment{Runners: runners, MinimumValueEdge: 0.05, MinimumValueProbability: 0.08}
	if !formOnly {
		s := domain.SourceLiveExchange
		a.MarketSource = &s
	}
	return a
}

func assessed(id string, p, odds float64) RunnerAssessment {
	return RunnerAssessment{HorseID: id, MarketProbability: fp(1 / odds), MarketBackPrice: fp(odds), WinProbability: p}
}

func TestValueAwareSelection(t *testing.T) {
	a := synthetic(false, assessed("favourite", 0.40, 2.2), assessed("value", 0.30, 4.5), assessed("longshot", 0.09, 15))
	if a.Selection().HorseID != "value" || a.MarketFavourite().HorseID != "favourite" {
		t.Fatal("prefers meaningful value")
	}
	a = synthetic(false, assessed("favourite", 0.45, 2.2), assessed("solid", 0.15, 7), assessed("longshot", 0.04, 30))
	if a.Selection().HorseID != "solid" {
		t.Fatal("does not chase tiny-probability longshots")
	}
	a = synthetic(false, assessed("favourite", 0.40, 2.2), assessed("second", 0.30, 3.2), assessed("third", 0.20, 5))
	if a.Selection().HorseID != "favourite" {
		t.Fatal("falls back to the highest probability")
	}
	a = synthetic(true, assessed("a", 0.45, 2), assessed("b", 0.35, 4))
	if a.Selection().HorseID != "a" {
		t.Fatal("form only picks the top")
	}
}

// v3 tips the most likely winner even where v2 would take the value.
func TestV3PicksTheMostLikelyWinner(t *testing.T) {
	if !V3().PicksMostLikelyWinner() || V2().PicksMostLikelyWinner() {
		t.Fatal("only v3 has the value layer off")
	}
	a := synthetic(false, assessed("favourite", 0.40, 2.2), assessed("value", 0.30, 4.5), assessed("longshot", 0.09, 15))
	a.MinimumValueProbability = V3().MinimumValueProbability
	if a.Selection().HorseID != "favourite" {
		t.Fatal("v3 ignores value")
	}
	v3 := NewRater(V3()).Rate(fourRunnerHandicap(), fullMarket(), nil, epoch)
	if v3.Selection().HorseID != v3.Runners[0].HorseID {
		t.Fatal("v3 tips the top-rated runner")
	}
	if v3.WeightsID != "v3" || v3.MinimumValueProbability != 1 {
		t.Fatal("the assessment carries the thresholds it was picked on")
	}
}

func TestWithoutAMarket(t *testing.T) {
	a := NewRater(V2()).Rate(fourRunnerHandicap(), nil, nil, epoch)
	if !a.IsFormOnly() || a.MarketCoverage != 0 || a.AgreesWithMarket() != nil || a.TrainingSnapshot != nil {
		t.Fatal("form only must say so")
	}
	if a.Selection().HorseID != "a" || a.Selection().WinProbability <= 0.25 {
		t.Fatal("top-rated with the best form")
	}
}

func TestThinMarketDiscardedWholesaleAndThresholdUsed(t *testing.T) {
	a := NewRater(V2()).Rate(fourRunnerHandicap(), market(map[string]float64{"a": 1.8, "b": 3.5}), nil, epoch)
	if !a.IsFormOnly() || !near(a.MarketCoverage, 0.5, 1e-4) {
		t.Fatal("thin market")
	}
	var rs []domain.Runner
	for i := 1; i <= 5; i++ {
		rs = append(rs, runner("h"+string(rune('0'+i)), runnerOpts{number: ip(i), or: ip(80 + i), form: sp("111")}))
	}
	b := NewRater(V2()).Rate(race("Test Stakes", domain.RaceTypeFlat, nil, sp("3yo+"), rs...), market(map[string]float64{"h1": 2, "h2": 4, "h3": 6, "h4": 8}), nil, epoch)
	if b.IsFormOnly() || !near(b.MarketCoverage, 0.8, 1e-4) {
		t.Fatal("the threshold is inclusive")
	}
}

func TestExplanations(t *testing.T) {
	a := NewRater(V2()).Rate(fourRunnerHandicap(), fullMarket(), nil, epoch)
	first := a.Runners[0]
	if len(first.Contributions) != len(AllFactors) {
		t.Fatal("a contribution per factor")
	}
	d := contribution(t, first, Draw)
	if d.Availability.IsAvailable() || d.ZScore != nil {
		t.Fatal("draw is inert")
	}
	best := contribution(t, runnerNamed(t, a, "a"), OfficialRating)
	worst := contribution(t, runnerNamed(t, a, "d"), OfficialRating)
	if best.ProbabilityDelta <= 0 || worst.ProbabilityDelta >= 0 {
		t.Fatal("leave-one-out deltas point the wrong way")
	}
	for _, id := range []FactorID{Draw, Headgear, JockeyStrikeRate, TrainerStrikeRate} {
		if c := contribution(t, first, id); c.Weight != 0 || c.ProbabilityDelta != 0 {
			t.Fatal(id)
		}
	}
	if a.ModelVersion != ModelVersion || a.WeightsID != "v2" || a.RaceID != "rac_test" || !a.IsMarketDelayed {
		t.Fatal("provenance")
	}
	if a.MarketFavourite().HorseID != "a" || a.AgreesWithMarket() == nil || a.TrainingSnapshot == nil {
		t.Fatal("favourite and snapshot")
	}
}

func TestEdges(t *testing.T) {
	empty := NewRater(V2()).Rate(race("x", domain.RaceTypeFlat, nil, nil), nil, nil, epoch)
	if len(empty.Runners) != 0 || empty.Selection() != nil || empty.Confidence != Low {
		t.Fatal("empty race")
	}
	one := NewRater(V2()).Rate(race("x", domain.RaceTypeFlat, nil, nil, runner("a", runnerOpts{or: ip(90)})), nil, nil, epoch)
	if one.Runners[0].WinProbability != 1 || one.Confidence != Low {
		t.Fatal("single runner")
	}
	var rs []domain.Runner
	for i := 1; i <= 6; i++ {
		rs = append(rs, domain.Runner{ID: "h" + string(rune('0'+i)), ClothNumber: ip(i)})
	}
	blank := NewRater(V2()).Rate(race("x", domain.RaceTypeFlat, nil, sp("3yo+"), rs...), nil, nil, epoch)
	for _, r := range blank.Runners {
		if !near(r.WinProbability, 1.0/6, 1e-6) || !near(r.FormScore, 0, 1e-6) {
			t.Fatal("knowing nothing rates uniformly")
		}
	}
	if blank.Confidence != Low {
		t.Fatal("confidence")
	}
	mo := NewRater(MarketOnly()).Rate(fourRunnerHandicap(), fullMarket(), nil, epoch)
	if e := mo.Runners[0].ValueEdge(); *e >= 0 || *e <= -0.2 {
		t.Fatal("at β=0 the only edge is the overround")
	}
}

func TestStrikeRateFactorsStaySilentOnThinArchive(t *testing.T) {
	r := race("x", domain.RaceTypeFlat, nil, sp("3yo+"),
		runner("a", runnerOpts{number: ip(1), or: ip(90), form: sp("111"), jockey: sp("jky_1")}),
		runner("b", runnerOpts{number: ip(2), or: ip(85), form: sp("222"), jockey: sp("jky_2")}))
	a := NewRater(V2()).Rate(r, nil, fakeStrikeRates{jockeys: map[string]StrikeRate{"jky_1": {3, 3}}, baseline: 0.1}, epoch)
	c := contribution(t, runnerNamed(t, a, "a"), JockeyStrikeRate)
	if c.Availability != (Availability{MissingData, "only 3 runs recorded so far"}) || c.ZScore != nil {
		t.Fatal(c.Availability)
	}
}

func TestSurfaceStrikeRateShrinksMatureCellsToTheGeneralRecord(t *testing.T) {
	archive := fakeStrikeRates{
		jockeys:        map[string]StrikeRate{"jockey": {Runs: 100, Wins: 20}},
		jockeySurfaces: map[string]StrikeRate{"jockey|turf": {Runs: 30, Wins: 10}},
		baseline:       0.125,
	}
	factor := surfaceStrikeRate{jockey: true, minimumSample: 30}
	r := runner("horse", runnerOpts{jockey: sp("jockey")})
	context := Context{Race: domain.Race{Surface: domain.SurfaceTurf}, StrikeRates: archive}
	reading := factor.Value(r, context)
	if reading.Raw == nil || !near(*reading.Raw, 0.275, 1e-9) || reading.Availability.Kind != Available {
		t.Fatalf("surface record was not shrunk to the general record: %#v", reading)
	}
	context.Race.Surface = domain.SurfaceAllWeather
	if reading := factor.Value(r, context); reading.Availability.Kind != MissingData || reading.Raw != nil {
		t.Fatalf("missing surface history must remain distinct from a neutral prior: %#v", reading)
	}
}

func TestRaceTypeStrikeRateRequiresThirtyRunsAndShrinksToTheGeneralRecord(t *testing.T) {
	archive := fakeStrikeRates{
		jockeys:         map[string]StrikeRate{"jockey": {Runs: 100, Wins: 20}},
		jockeyRaceTypes: map[string]StrikeRate{"jockey|flat": {Runs: 30, Wins: 10}},
		baseline:        0.125,
	}
	factor := raceTypeStrikeRate{jockey: true, minimumSample: 30}
	r := runner("horse", runnerOpts{jockey: sp("jockey")})
	context := Context{Race: domain.Race{Type: domain.RaceTypeFlat}, StrikeRates: archive}
	reading := factor.Value(r, context)
	if reading.Raw == nil || !near(*reading.Raw, 0.275, 1e-9) || reading.Availability.Kind != Available {
		t.Fatalf("race-type record was not shrunk to the general record: %#v", reading)
	}
	archive.jockeyRaceTypes["jockey|flat"] = StrikeRate{Runs: 29, Wins: 10}
	context.StrikeRates = archive
	reading = factor.Value(r, context)
	if reading.Raw != nil || reading.Availability.Kind != MissingData {
		t.Fatalf("race-type record below the sample floor must be missing: %#v", reading)
	}
	context.Race.Type = domain.RaceTypeUnknown
	reading = factor.Value(r, context)
	if reading.Raw != nil || reading.Availability.Reason != "race type is unknown" {
		t.Fatalf("unknown race type must be missing: %#v", reading)
	}
}

func TestHorseGoingFactorUsesOnlyMatureBucketHistory(t *testing.T) {
	factor := horseGoing{minimumSample: 3}
	archive := fakeStrikeRates{
		horseGoings:  map[string]PlaceRate{"horse|turf|soft": {Runs: 3, Places: 2}},
		horseOverall: map[string]PlaceRate{"horse": {Runs: 4, Places: 3}},
	}
	context := Context{Race: domain.Race{Going: domain.GoingHeavy, Surface: domain.SurfaceTurf}, StrikeRates: archive}
	got := factor.Value(runner("horse", runnerOpts{}), context)
	if got.Raw == nil || !near(*got.Raw, 0.545, 0.001) || got.Availability.Kind != Available {
		t.Fatalf("expected smoothed soft-bucket place rate, got %#v", got)
	}
	context.Race.Going = domain.GoingGood
	if got := factor.Value(runner("horse", runnerOpts{}), context); got.Availability.Kind != Available || got.Raw == nil || !near(*got.Raw, 0.472, 0.001) {
		t.Fatalf("thin going bucket must fall back to general horse form: %#v", got)
	}
	if got := factor.Value(runner("new-horse", runnerOpts{}), context); got.Availability.Kind != Available || got.Raw == nil || !near(*got.Raw, 0.25, 1e-9) {
		t.Fatalf("no mature history must use the field prior: %#v", got)
	}
}

func TestGoingStrikeRateRequiresThirtyRunsAndShrinksToTheGeneralRecord(t *testing.T) {
	archive := fakeStrikeRates{
		jockeys:      map[string]StrikeRate{"jockey": {Runs: 100, Wins: 20}},
		jockeyGoings: map[string]StrikeRate{"jockey|turf|good": {Runs: 30, Wins: 10}},
		baseline:     0.125,
	}
	factor := goingStrikeRate{jockey: true, minimumSample: 30}
	r := runner("horse", runnerOpts{jockey: sp("jockey")})
	context := Context{Race: domain.Race{Surface: domain.SurfaceTurf, Going: domain.GoingGood}, StrikeRates: archive}
	reading := factor.Value(r, context)
	if reading.Raw == nil || !near(*reading.Raw, 0.275, 1e-9) || reading.Availability.Kind != Available {
		t.Fatalf("going record was not shrunk to the general record: %#v", reading)
	}
	context.Race.Going = domain.GoingUnknown
	reading = factor.Value(r, context)
	if reading.Raw != nil || reading.Availability.Reason != "going or surface is unknown" {
		t.Fatalf("unknown going must be missing: %#v", reading)
	}
}

func TestRecentStrikeRateRequiresThirtyDatedRunsAndShrinksTowardTheGeneralRate(t *testing.T) {
	archive := fakeStrikeRates{
		jockeys:      map[string]StrikeRate{"jockey": {Runs: 100, Wins: 20}},
		jockeyRecent: map[string]StrikeRate{"jockey": {Runs: 30, Wins: 10}},
		baseline:     0.125,
	}
	factor := recentStrikeRate{jockey: true, minimumSample: 30}
	r := runner("horse", runnerOpts{jockey: sp("jockey")})
	reading := factor.Value(r, Context{StrikeRates: archive})
	if reading.Raw == nil || !near(*reading.Raw, 0.275, 1e-9) || reading.Availability.Kind != Available {
		t.Fatalf("recent rate was not shrunk to the general record: %#v", reading)
	}
	archive.jockeyRecent["jockey"] = StrikeRate{Runs: 29, Wins: 10}
	reading = factor.Value(r, Context{StrikeRates: archive})
	if reading.Raw != nil || reading.Availability != (Availability{MissingData, "only 29 dated runs in the recent window"}) {
		t.Fatalf("recent rate below the sample floor must be missing: %#v", reading)
	}
}

func TestJockeyTrainerInteractionNeedsMaturePairAndIndividualRecords(t *testing.T) {
	factor := jockeyTrainerStrikeRate{minimumSample: 30}
	r := runner("horse", runnerOpts{jockey: sp("jockey"), trainer: sp("trainer")})
	archive := fakeStrikeRates{
		jockeys:       map[string]StrikeRate{"jockey": {Runs: 100, Wins: 20}},
		trainers:      map[string]StrikeRate{"trainer": {Runs: 100, Wins: 30}},
		jockeyTrainer: map[string]StrikeRate{"jockey|trainer": {Runs: 30, Wins: 12}},
		baseline:      0.125,
	}
	reading := factor.Value(r, Context{StrikeRates: archive})
	if reading.Raw == nil || reading.Availability.Kind != Available || !near(*reading.Raw, 0.33166666666666667, 1e-9) {
		t.Fatalf("mature interaction did not use the individual prior: %#v", reading)
	}
	archive.jockeyTrainer["jockey|trainer"] = StrikeRate{Runs: 29, Wins: 12}
	reading = factor.Value(r, Context{StrikeRates: archive})
	if reading.Raw != nil || reading.Availability.Kind != MissingData {
		t.Fatalf("thin interaction must be missing: %#v", reading)
	}
	archive.jockeyTrainer["jockey|trainer"] = StrikeRate{Runs: 30, Wins: 12}
	archive.trainers["trainer"] = StrikeRate{Runs: 29, Wins: 10}
	reading = factor.Value(r, Context{StrikeRates: archive})
	if reading.Raw != nil || reading.Availability.Reason != "jockey and trainer need enough individual runs" {
		t.Fatalf("interaction must require mature individual records: %#v", reading)
	}
}

func TestDrawBiasUsesComparableStartsAndRequiresOneHundred(t *testing.T) {
	factor := draw{}
	r := runner("horse", runnerOpts{draw: ip(2)})
	context := Context{Race: domain.Race{Type: domain.RaceTypeFlat}, StrikeRates: fakeStrikeRates{
		drawBiasRecord: DrawBiasRate{Runs: 100, Wins: 20, ExpectedWins: 10}, drawBiasExists: true,
	}}
	reading := factor.Value(r, context)
	if reading.Raw == nil || reading.Availability.Kind != Available || !near(*reading.Raw, 22.0/120.0, 1e-9) {
		t.Fatalf("mature draw cell was not shrunk to its expected rate: %#v", reading)
	}
	archive := context.StrikeRates.(fakeStrikeRates)
	archive.drawBiasRecord.Runs = 99
	context.StrikeRates = archive
	reading = factor.Value(r, context)
	if reading.Raw != nil || reading.Availability.Reason != "only 99 comparable starters for this draw" {
		t.Fatalf("thin draw cell must remain missing: %#v", reading)
	}
}

func TestClassAdjustedFormUsesHistoryOnlyAboveThreeRuns(t *testing.T) {
	factor := classAdjustedForm{minimumSample: 3}
	context := Context{Race: domain.Race{RaceClass: ip(3)}, StrikeRates: fakeStrikeRates{
		horseClassRate: ClassAdjustedFormRate{Runs: 3, Score: 0.6}, horseClassExists: true,
	}}
	reading := factor.Value(runner("horse", runnerOpts{}), context)
	if reading.Raw == nil || !near(*reading.Raw, 0.55, 1e-9) || reading.Availability.Kind != Available {
		t.Fatalf("class-adjusted form did not shrink to neutral: %#v", reading)
	}
	archive := context.StrikeRates.(fakeStrikeRates)
	archive.horseClassRate.Runs = 2
	context.StrikeRates = archive
	reading = factor.Value(runner("horse", runnerOpts{}), context)
	if reading.Raw != nil || reading.Availability.Reason != "only 2 classed runs for this horse" {
		t.Fatalf("thin class history must be missing: %#v", reading)
	}
}

func TestMarketMovementRequiresFiveMinutesOfPreSealExchangePrices(t *testing.T) {
	start := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	finish := start.Add(6 * time.Minute)
	firstObserved := domain.At(start)
	current := domain.MarketSnapshot{
		Source: domain.SourceLiveExchange, CapturedAt: domain.At(finish),
		FirstObservedAt:     &firstObserved,
		FirstObservedPrices: map[string]domain.RunnerPrice{"horse": {BackPrice: fp(2.0), IsActive: true}},
		Prices:              map[string]domain.RunnerPrice{"horse": {BackPrice: fp(1.8), IsActive: true}},
	}
	factor := marketMovement{}
	r := runner("horse", runnerOpts{})
	reading := factor.Value(r, Context{Market: &current, Now: finish})
	if reading.Raw == nil || !near(*reading.Raw, 1.0/1.8-0.5, 1e-9) || reading.Availability.Kind != Available {
		t.Fatalf("market movement was not the change in implied chance: %#v", reading)
	}
	tooEarly := current
	tooEarly.CapturedAt = domain.At(start.Add(4 * time.Minute))
	reading = factor.Value(r, Context{Market: &tooEarly, Now: finish})
	if reading.Raw != nil || reading.Availability.Reason != "market movement needs at least five minutes of prices" {
		t.Fatalf("short market window must be missing: %#v", reading)
	}
	reading = factor.Value(r, Context{Market: &current, Now: start.Add(5 * time.Minute)})
	if reading.Raw != nil || reading.Availability.Reason != "market movement includes prices after the rating time" {
		t.Fatalf("post-seal prices must not be used: %#v", reading)
	}
}

// FactorDescriptionTests: every factor has copy, the presets name every
// factor, and the set of deliberate zeros does not change silently.
func TestFactorDescriptions(t *testing.T) {
	zeros := map[FactorID]bool{}
	for _, id := range AllFactors {
		if id.Label() == string(id) || id.Summary() == "" {
			t.Fatalf("%s has no copy", id)
		}
		w, ok := V1().FactorWeights[string(id)]
		if !ok {
			t.Fatalf("v1 omits %s", id)
		}
		if w == 0 {
			zeros[id] = true
			if id.Rationale() == "" {
				t.Fatalf("%s ships at zero with no rationale", id)
			}
		}
	}
	want := map[FactorID]bool{Draw: true, Headgear: true, JockeyStrikeRate: true, TrainerStrikeRate: true, JockeySurfaceStrikeRate: true, TrainerSurfaceStrikeRate: true, JockeyRaceTypeStrikeRate: true, TrainerRaceTypeStrikeRate: true, JockeyGoingStrikeRate: true, TrainerGoingStrikeRate: true, HorseGoingPlaceRate: true, JockeyRecentStrikeRate: true, TrainerRecentStrikeRate: true, JockeyTrainerStrikeRate: true, ClassAdjustedForm: true, MarketMovement: true}
	if len(zeros) != len(want) {
		t.Fatal("the set of deliberate zeros changed", zeros)
	}
}
