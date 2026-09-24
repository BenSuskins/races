package tracking

import (
	"encoding/json"
	"math"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
)

var off = time.Unix(1_800_000_000, 0).UTC()

func fp(v float64) *float64 { return &v }
func ip(v int) *int         { return &v }
func bp(v bool) *bool       { return &v }
func sp(v string) *string   { return &v }

func near(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

type tipOpts struct {
	raceID, selection string
	offAt             *time.Time
	noOff             bool
	probability       float64
	favourite         *string
	agreed            *bool
	outcome           *Outcome
	favouriteOutcome  *FavouriteOutcome
	ref               *domain.MarketReference
}

// makeTip mirrors TipRecord.make.
func makeTip(o tipOpts) Tip {
	if o.raceID == "" {
		o.raceID = "rac_1"
	}
	if o.selection == "" {
		o.selection = "hrs_1"
	}
	if o.probability == 0 {
		o.probability = 0.30
	}
	t := Tip{
		RaceID: o.raceID, RaceDate: "2026-09-20", CourseName: "Ascot", RaceName: "Test Handicap",
		RaceType: domain.RaceTypeFlat, FieldSizeAtTip: 8, SelectionHorseID: o.selection,
		SelectionHorseName: o.selection, PredictedProbability: o.probability,
		MarketProbabilityAtTip: fp(0.28), MarketBackPriceAtTip: fp(3.5),
		MarketFavouriteHorseID: o.favourite, AgreedWithFavourite: o.agreed, Confidence: rating.Medium,
		ModelVersion: rating.ModelVersion, WeightsID: "v1", Contributions: []rating.Contribution{},
		MarketReference: o.ref, CreatedAt: domain.At(time.Unix(1_799_990_000, 0)),
		Outcome: o.outcome, FavouriteOutcome: o.favouriteOutcome,
	}
	switch {
	case o.noOff:
	case o.offAt != nil:
		t.OffAt = domain.Ptr(*o.offAt)
	default:
		t.OffAt = domain.Ptr(off)
	}
	return t
}

func result(finishing [][2]string, sps map[string]float64) *domain.RaceResult {
	r := &domain.RaceResult{ID: "rac_1", CourseName: "Ascot", Name: "Test Handicap", Date: "2026-09-20"}
	for _, f := range finishing {
		pos := f[1]
		fin := domain.Finisher{HorseID: f[0], HorseName: f[0], Position: domain.ParseFinishPosition(&pos)}
		if p, ok := sps[f[0]]; ok {
			fin.StartingPriceDecimal = fp(p)
		}
		r.Finishers = append(r.Finishers, fin)
	}
	return r
}

func ledgerRace(offAt *time.Time) domain.Race {
	r := domain.Race{
		ID: "rac_1", CourseName: "Ascot", Name: "Test Handicap", OffTime: "14:30", Date: "2026-09-20",
		Runners: []domain.Runner{
			{ID: "hrs_1", Name: "One", ClothNumber: ip(1), OfficialRating: ip(90), Form: sp("111")},
			{ID: "hrs_2", Name: "Two", ClothNumber: ip(2), OfficialRating: ip(80), Form: sp("222")},
		},
	}
	if offAt != nil {
		r.OffDateTime = domain.Ptr(*offAt)
	}
	return r
}

func record(l *Ledger, r domain.Race, now time.Time) RecordOutcome {
	return l.Record(rating.NewRater(rating.V2()).Rate(r, nil, nil, now), r, nil, now)
}

// MARK: - Sealing rule

func TestSealingRule(t *testing.T) {
	r := ledgerRace(&off)
	l := NewLedger()
	if got := record(l, r, off.Add(-2*time.Hour)); got != Created {
		t.Fatal(got)
	}
	if got := record(l, r, off.Add(-time.Hour)); got != Updated || len(l.Storage) != 1 {
		t.Fatal(got)
	}
	justInside := off.Add(-SealWindow + time.Second)
	if got := record(l, r, justInside); got != Sealed || !l.Storage["rac_1"].SealedAt.Equal(justInside) {
		t.Fatal(got)
	}
	if got := record(l, r, off.Add(-30*time.Second)); got != RejectedAlreadySealed || !l.Storage["rac_1"].SealedAt.Equal(justInside) {
		t.Fatal("the seal time must not move")
	}

	l = NewLedger()
	if got := record(l, r, off.Add(-SealWindow-time.Second)); got != Created || l.Storage["rac_1"].IsSealed() {
		t.Fatal("just outside the window is a draft")
	}
	if got := record(l, r, off.Add(time.Minute)); got != RejectedRaceStarted {
		t.Fatal("a draft is not updated once the race has run")
	}

	l = NewLedger()
	if got := record(l, r, off.Add(time.Second)); got != RejectedRaceStarted || len(l.Storage) != 0 || got.DidStore() {
		t.Fatal("a race that has run is never recorded")
	}
	if got := record(l, ledgerRace(nil), off); got != Sealed {
		t.Fatal("no off time seals immediately")
	}
	empty := domain.Race{ID: "rac_empty", OffDateTime: domain.Ptr(off)}
	if got := record(NewLedger(), empty, off.Add(-time.Hour)); got != RejectedNoSelection {
		t.Fatal(got)
	}
}

func TestSettleOnceOnly(t *testing.T) {
	l := NewLedger()
	if l.Settle("nope", Outcome{Kind: Won}, nil) {
		t.Fatal("unknown race")
	}
	l = NewLedger(makeTip(tipOpts{outcome: &Outcome{Kind: Won, BetfairSP: fp(4)}}))
	if l.Settle("rac_1", Outcome{Kind: Lost}, nil) {
		t.Fatal("a settled tip does not un-settle")
	}
	l = NewLedger(makeTip(tipOpts{outcome: &Outcome{Kind: NonRunner}}))
	if l.Settle("rac_1", Outcome{Kind: Won}, nil) {
		t.Fatal("nor does a void one")
	}
	l = NewLedger(makeTip(tipOpts{outcome: &Outcome{Kind: Unresolved, Attempts: 2}}))
	if !l.Settle("rac_1", Outcome{Kind: Won}, &FavouriteOutcome{HorseID: "hrs_1", Won: true}) || !l.Storage["rac_1"].FavouriteOutcome.Won {
		t.Fatal("unresolved can still settle")
	}
}

func TestAwaitingReconciliation(t *testing.T) {
	before, after := off.Add(-time.Hour), off.Add(time.Hour)
	ref := &domain.MarketReference{MarketID: "1.100"}
	tips := []Tip{
		makeTip(tipOpts{raceID: "pending", offAt: &before, ref: ref}),
		makeTip(tipOpts{raceID: "unresolved", offAt: &before, outcome: &Outcome{Kind: Unresolved}, ref: &domain.MarketReference{MarketID: "1.050"}}),
		makeTip(tipOpts{raceID: "settled", offAt: &before, outcome: &Outcome{Kind: Won}, ref: &domain.MarketReference{MarketID: "1.999"}}),
		makeTip(tipOpts{raceID: "future", offAt: &after, ref: ref}),
	}
	waiting := 0
	for _, tip := range tips {
		if AwaitingReconciliation(tip, off) {
			waiting++
		}
	}
	if waiting != 2 {
		t.Fatal(waiting)
	}
	if ids := MarketIDsAwaitingStartingPrice(tips, off); len(ids) != 2 || ids[0] != "1.050" || ids[1] != "1.100" {
		t.Fatal(ids)
	}
}

// MARK: - Reconciler

func TestSettlement(t *testing.T) {
	evening := off.Add(4 * time.Hour)
	three := [][2]string{{"hrs_1", "1"}, {"hrs_2", "2"}, {"hrs_3", "3"}}

	got := Settle(makeTip(tipOpts{}), result(three, map[string]float64{"hrs_1": 4.2}), nil, false, evening)
	if got.Outcome.Kind != Won || *got.Outcome.BetfairSP != 4.2 {
		t.Fatal("won")
	}
	got = Settle(makeTip(tipOpts{selection: "hrs_2"}), result([][2]string{{"hrs_1", "1"}, {"hrs_2", "4"}, {"hrs_3", "3"}}, map[string]float64{"hrs_2": 6}), nil, false, evening)
	if got.Outcome.Kind != Lost || *got.Outcome.Position != 4 {
		t.Fatal("lost fourth")
	}
	got = Settle(makeTip(tipOpts{selection: "hrs_2"}), result([][2]string{{"hrs_1", "1"}, {"hrs_2", "PU"}, {"hrs_3", "2"}}, nil), nil, false, evening)
	if got.Outcome.Kind != Lost || got.Outcome.Position != nil || got.Outcome.BetfairSP != nil {
		t.Fatal("pulled up is lost with no position")
	}
	got = Settle(makeTip(tipOpts{}), result(three, map[string]float64{"hrs_1": 4}), map[string]float64{"hrs_1": 4.6}, false, evening)
	if *got.Outcome.BetfairSP != 4.6 {
		t.Fatal("Betfair SP wins")
	}
	got = Settle(makeTip(tipOpts{selection: "hrs_9"}), result(three, nil), nil, false, evening)
	if got.Outcome.Kind != NonRunner || !got.Outcome.IsVoid() || got.Outcome.IsSettled() {
		t.Fatal("withdrawn is void")
	}
	if got = Settle(makeTip(tipOpts{}), nil, nil, true, evening); got.Outcome.Kind != Abandoned {
		t.Fatal("abandoned")
	}
	if got = Settle(makeTip(tipOpts{selection: "hrs_9"}), result([][2]string{{"hrs_1", "1"}}, nil), nil, false, evening); got.Outcome.Kind != Unresolved {
		t.Fatal("a truncated result settles nothing")
	}
}

func TestMissingResults(t *testing.T) {
	evening := off.Add(4 * time.Hour)
	tip := Settle(makeTip(tipOpts{}), nil, nil, false, evening)
	tip = Settle(tip, nil, nil, false, evening)
	if tip.Outcome.Kind != Unresolved || tip.Outcome.Attempts != 2 {
		t.Fatal("counts attempts")
	}
	if got := Settle(makeTip(tipOpts{}), nil, nil, false, off.Add((ExpiryDays+1)*24*time.Hour)); got.Outcome.Kind != Expired {
		t.Fatal("too old")
	}
	if got := Settle(makeTip(tipOpts{outcome: &Outcome{Kind: Unresolved, Attempts: MaximumAttempts - 1}}), nil, nil, false, evening); got.Outcome.Kind != Expired {
		t.Fatal("too many attempts")
	}
}

func TestFavouriteBaselineCapture(t *testing.T) {
	evening := off.Add(4 * time.Hour)
	three := [][2]string{{"hrs_1", "1"}, {"hrs_2", "2"}, {"hrs_3", "3"}}
	got := Settle(makeTip(tipOpts{selection: "hrs_2", favourite: sp("hrs_1"), agreed: bp(false)}), result(three, map[string]float64{"hrs_1": 2.5}), nil, false, evening)
	if f := got.FavouriteOutcome; f == nil || f.HorseID != "hrs_1" || !f.Won || *f.BetfairSP != 2.5 {
		t.Fatal("favourite captured")
	}
	got = Settle(makeTip(tipOpts{selection: "hrs_2", favourite: sp("hrs_9")}), result(three, nil), nil, false, evening)
	if got.FavouriteOutcome != nil {
		t.Fatal("a non-running favourite is not a losing favourite")
	}
}

// MARK: - Accuracy

func tipWith(id string, outcome *Outcome, p float64, agreed *bool, fav *FavouriteOutcome) Tip {
	return makeTip(tipOpts{raceID: id, outcome: outcome, probability: p, agreed: agreed, favouriteOutcome: fav})
}

func TestAccuracyDenominators(t *testing.T) {
	r := Accuracy([]Tip{
		tipWith("a", &Outcome{Kind: Won, BetfairSP: fp(4)}, 0.25, nil, nil),
		tipWith("b", &Outcome{Kind: Lost, BetfairSP: fp(6)}, 0.25, nil, nil),
		tipWith("c", &Outcome{Kind: NonRunner}, 0.25, nil, nil),
		tipWith("d", &Outcome{Kind: Abandoned}, 0.25, nil, nil),
		tipWith("e", &Outcome{Kind: Unresolved}, 0.25, nil, nil),
		tipWith("f", &Outcome{Kind: Expired}, 0.25, nil, nil),
		tipWith("g", nil, 0.25, nil, nil),
	}, DefaultCommission)
	if r.Total != 7 || r.Settled != 2 || r.Wins != 1 || r.Voided != 2 || r.Unresolved != 1 || r.Expired != 1 || r.Pending != 1 {
		t.Fatalf("%+v", r)
	}
	if !near(r.Coverage, 4.0/6.0) {
		t.Fatal(r.Coverage)
	}
	empty := Accuracy(nil, DefaultCommission)
	if empty.ROI != nil || empty.BrierScore != nil || empty.Coverage != 1 {
		t.Fatal("empty reports nothing, not zero")
	}
}

func TestROINetOfCommission(t *testing.T) {
	tips := []Tip{tipWith("win", &Outcome{Kind: Won, BetfairSP: fp(5)}, 0.25, nil, nil)}
	for _, id := range []string{"l1", "l2", "l3", "l4"} {
		tips = append(tips, tipWith(id, &Outcome{Kind: Lost, BetfairSP: fp(8)}, 0.25, nil, nil))
	}
	r := Accuracy(tips, 0.05)
	if r.ROI.Bets != 5 || !near(r.ROI.Returned, 4.80) {
		t.Fatalf("%+v", r.ROI)
	}
	if r := Accuracy(tips[:1], 0); !near(r.ROI.Returned, 5) {
		t.Fatal("zero commission")
	}
	r = Accuracy([]Tip{
		tipWith("priced", &Outcome{Kind: Won, BetfairSP: fp(4)}, 0.25, nil, nil),
		tipWith("unpriced", &Outcome{Kind: Won}, 0.25, nil, nil),
		tipWith("lost", &Outcome{Kind: Lost}, 0.25, nil, nil),
	}, 0.05)
	if r.Settled != 3 || r.ROI.Bets != 1 || r.SettledWithoutPrice != 2 {
		t.Fatal("separate denominators")
	}
}

func TestFavouriteBaselineAndSplit(t *testing.T) {
	r := Accuracy([]Tip{
		tipWith("a", &Outcome{Kind: Won, BetfairSP: fp(4)}, 0.25, bp(false), &FavouriteOutcome{HorseID: "fav", Won: true, BetfairSP: fp(2)}),
		tipWith("b", &Outcome{Kind: Lost, BetfairSP: fp(8)}, 0.25, bp(false), &FavouriteOutcome{HorseID: "fav", Won: true, BetfairSP: fp(2.5)}),
	}, 0.05)
	if r.FavouriteBaseline.Settled != 2 || r.FavouriteBaseline.Wins != 2 {
		t.Fatal("baseline over the same races")
	}
	r = Accuracy([]Tip{
		tipWith("aw", &Outcome{Kind: Won, BetfairSP: fp(2)}, 0.25, bp(true), nil),
		tipWith("al", &Outcome{Kind: Lost, BetfairSP: fp(2)}, 0.25, bp(true), nil),
		tipWith("dw", &Outcome{Kind: Won, BetfairSP: fp(9)}, 0.25, bp(false), nil),
		tipWith("dl1", &Outcome{Kind: Lost, BetfairSP: fp(9)}, 0.25, bp(false), nil),
		tipWith("dl2", &Outcome{Kind: Lost, BetfairSP: fp(9)}, 0.25, bp(false), nil),
	}, 0.05)
	if r.WhenAgreeingWithFavourite.Settled != 2 || r.WhenDisagreeing.Settled != 3 || !near(r.WhenDisagreeing.ROI.Returned, 8.60) {
		t.Fatalf("%+v", r.WhenDisagreeing)
	}
}

// MARK: - Wire format

// The shapes Swift's synthesised Codable writes. A device upload is decoded
// with these, and the app decodes the server's tips with its own TipRecord.
func TestOutcomeMatchesSwiftCodable(t *testing.T) {
	cases := map[string]Outcome{
		`{"won":{"betfairSP":4.2}}`:                 {Kind: Won, BetfairSP: fp(4.2)},
		`{"won":{}}`:                                {Kind: Won},
		`{"lost":{"position":4}}`:                   {Kind: Lost, Position: ip(4)},
		`{"nonRunner":{}}`:                          {Kind: NonRunner},
		`{"expired":{"at":"2027-01-15T08:00:00Z"}}`: {Kind: Expired, At: domain.At(time.Date(2027, 1, 15, 8, 0, 0, 0, time.UTC))},
		`{"unresolved":{"lastCheckedAt":"2027-01-15T08:00:00Z","attempts":2}}`: {Kind: Unresolved, Attempts: 2, LastCheckedAt: domain.At(time.Date(2027, 1, 15, 8, 0, 0, 0, time.UTC))},
	}
	for wire, value := range cases {
		out, err := json.Marshal(value)
		if err != nil || string(out) != wire {
			t.Fatalf("marshal: got %s want %s (%v)", out, wire, err)
		}
		var back Outcome
		if err := json.Unmarshal([]byte(wire), &back); err != nil {
			t.Fatal(err)
		}
		again, _ := json.Marshal(back)
		if string(again) != wire {
			t.Fatalf("round trip: %s", again)
		}
	}
}

func TestLedgerRoundTrip(t *testing.T) {
	l := NewLedger(makeTip(tipOpts{}), makeTip(tipOpts{raceID: "rac_2", selection: "hrs_9"}))
	data, _ := json.Marshal(l)
	var back Ledger
	if err := json.Unmarshal(data, &back); err != nil || back.Storage["rac_2"].SelectionHorseID != "hrs_9" {
		t.Fatal(err)
	}
}

func TestArchiveIsIdempotent(t *testing.T) {
	a := NewArchive()
	r := result([][2]string{{"a", "1"}, {"b", "2"}}, nil)
	r.Finishers[0].JockeyID = sp("j1")
	r.Finishers[1].JockeyID = sp("j1")
	if !a.Ingest(*r) || a.Ingest(*r) {
		t.Fatal("second ingest must be refused")
	}
	if s, _ := a.JockeyStrikeRate("j1"); s.Runs != 2 || s.Wins != 1 || a.TotalRuns != 2 {
		t.Fatalf("%+v", s)
	}
	if a.BaselineStrikeRate() != 0.125 {
		t.Fatal("prior until 100 runs")
	}
	other := NewArchive()
	r2 := *r
	r2.ID = "rac_2"
	other.Ingest(r2)
	if a.Merge(*other) != 1 || a.TotalRuns != 4 {
		t.Fatal("disjoint merge adds counts")
	}
	if a.Merge(*other) != 0 || a.TotalRuns != 4 {
		t.Fatal("repeat merge is a no-op")
	}
}
