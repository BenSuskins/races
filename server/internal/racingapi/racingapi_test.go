package racingapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/httpx"
)

var now = time.Date(2026, 9, 20, 12, 0, 0, 0, time.UTC)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func races(t *testing.T) map[string]domain.Race {
	t.Helper()
	list, err := ParseRacecards(fixture(t, "racingapi-racecards-free.json"), now)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]domain.Race{}
	for _, r := range list {
		out[r.ID] = r
	}
	if len(list) != 2 {
		t.Fatalf("the race with no id must be dropped, got %d", len(list))
	}
	return out
}

func runner(t *testing.T, race domain.Race, id string) domain.Runner {
	for _, r := range race.Runners {
		if r.ID == id {
			return r
		}
	}
	t.Fatalf("no %s", id)
	return domain.Runner{}
}

func TestRacecardMapping(t *testing.T) {
	all := races(t)
	ascot := all["rac_1001"]
	if ascot.Going != domain.GoingGoodToFirm || ascot.Type != domain.RaceTypeFlat || *ascot.RaceClass != 3 ||
		ascot.Distance.Furlongs != 8 || *ascot.RatingBand != (domain.ClosedRange{Lower: 0, Upper: 95}) ||
		*ascot.FieldSize != 4 || *ascot.Prize != "£12,450" || *ascot.RegionCode != "gb" || ascot.Pattern != nil {
		t.Fatalf("%+v", ascot)
	}
	if !ascot.IsHandicap() || all["rac_1002"].IsHandicap() {
		t.Fatal("handicap from the title")
	}
	// No off_dt: "3:05" on the card is five past three in the afternoon.
	if got := all["rac_1002"].OffDateTime.In(domain.London).Format("2006-01-02 15:04"); got != "2026-09-20 15:05" {
		t.Fatal(got)
	}
}

func TestRunnersAreLenient(t *testing.T) {
	all := races(t)
	k := runner(t, all["rac_1001"], "hrs_1")
	if *k.ClothNumber != 1 || *k.Draw != 3 || *k.OfficialRating != 95 || *k.WeightPounds != 133 || *k.DaysSinceLastRun != 21 || *k.Form != "1-3241" || *k.Headgear != "b" {
		t.Fatal("quoted numbers")
	}
	n := runner(t, all["rac_1001"], "hrs_4")
	if *n.ClothNumber != 4 || *n.OfficialRating != 88 || *n.DaysSinceLastRun != 35 {
		t.Fatal("bare numbers")
	}
	u := runner(t, all["rac_1001"], "hrs_3")
	if u.OfficialRating != nil || u.DaysSinceLastRun != nil || u.Form != nil || u.Headgear != nil {
		t.Fatal(`"" and "-" and null are unknown, never zero`)
	}
	if runner(t, all["rac_1002"], "hrs_5").Draw != nil || runner(t, all["rac_1002"], "hrs_6").Draw != nil {
		t.Fatal("jumps runners have no draw")
	}
	if runner(t, all["rac_1002"], "hrs_5").WeightDisplay() != "11-07" {
		t.Fatal("weight display")
	}
}

func TestResultMapping(t *testing.T) {
	results, err := ParseResults(fixture(t, "racingapi-results-today-free.json"), now)
	if err != nil || len(results) != 2 {
		t.Fatal(err)
	}
	ascot, wetherby := results[0], results[1]
	if ascot.Winner().HorseID != "hrs_2" || ascot.Finisher("hrs_4").Position != domain.Finished(3) || *ascot.RaceClass != 3 {
		t.Fatal("quoted and unquoted positions")
	}
	if wetherby.Finisher("hrs_5").Position.Kind != domain.PositionPulledUp || wetherby.Finisher("hrs_7").Position.Kind != domain.PositionFell {
		t.Fatal("non-completions")
	}
	if ran, ok := ascot.DidRun("hrs_3"); !ok || ran {
		t.Fatal("hrs_3 was declared but did not run")
	}
}

func TestRaceClassAndBand(t *testing.T) {
	s := func(v string) *string { return &v }
	if *raceClass(s("Class 4")) != 4 || *raceClass(s("4")) != 4 || raceClass(nil) != nil || raceClass(s("Class 9")) != nil {
		t.Fatal("race class")
	}
	if ratingBand(s("95-0")) != nil || *ratingBand(s("0-85")) != (domain.ClosedRange{Lower: 0, Upper: 85}) {
		t.Fatal("band")
	}
}

func TestLenientNumbersAndText(t *testing.T) {
	var v struct {
		A, B, C, D, E Number
		P             Text
		Q             Text
	}
	if err := json.Unmarshal([]byte(`{"A":7,"B":"7.0","C":"-","D":{"x":1},"E":null,"P":1,"Q":"  PU "}`), &v); err != nil {
		t.Fatal(err)
	}
	if *v.A.Int() != 7 || *v.B.Int() != 7 || v.C.Int() != nil || v.D.Int() != nil || v.E.Int() != nil {
		t.Fatal("numbers")
	}
	if *v.P.Value != "1" || *v.Q.Value != "PU" {
		t.Fatal("text")
	}
}

func TestClientEndpointsAndTierLatch(t *testing.T) {
	var formCalls atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/racecards/free":
			if r.URL.Query().Get("day") != "tomorrow" {
				t.Errorf("day %s", r.URL.Query().Get("day"))
			}
			w.Write(fixture(t, "racingapi-racecards-free.json"))
		case "/v1/results/today/free":
			w.Write(fixture(t, "racingapi-results-today-free.json"))
		case "/v1/courses":
			w.Write(fixture(t, "racingapi-courses.json"))
		default:
			formCalls.Add(1)
			w.WriteHeader(403)
		}
	}))
	defer s.Close()
	c := New(s.URL, "u", "p", httpx.New(s.URL, 0, nil))
	ctx := context.Background()
	if r, err := c.Racecards(ctx, domain.Tomorrow, "gb"); err != nil || len(r) != 2 {
		t.Fatal(err)
	}
	if r, err := c.TodaysResults(ctx); err != nil || len(r) != 2 {
		t.Fatal(err)
	}
	if cs, err := c.Courses(ctx, "gb", "ire"); err != nil || len(cs) != 5 {
		t.Fatal(err, len(cs))
	}
	for range 3 {
		if _, err := c.FormHistory(ctx, "hrs_1"); httpx.KindOf(err) != httpx.TierUnavailable {
			t.Fatal(err)
		}
	}
	if formCalls.Load() != 1 {
		t.Fatal("the 403 must latch", formCalls.Load())
	}
	if _, err := New(s.URL, "", "p", nil).Courses(ctx); !IsNotConfigured(err) {
		t.Fatal("half-configured is not configured")
	}
}
