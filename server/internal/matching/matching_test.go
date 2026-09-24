package matching

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
)

var baseOff = time.Unix(1_789_997_400, 0).UTC()

func at(minutes float64) time.Time { return baseOff.Add(time.Duration(minutes * float64(time.Minute))) }
func ip(v int) *int                { return &v }

type numbered struct {
	name  string
	cloth *int
}

func testRace(id, course string, off *time.Time, horses ...numbered) domain.Race {
	r := domain.Race{ID: id, CourseName: course, Name: "Test Handicap", OffTime: "14:30", Date: "2026-09-21"}
	if off != nil {
		r.OffDateTime = domain.Ptr(*off)
	}
	for i, h := range horses {
		r.Runners = append(r.Runners, domain.Runner{ID: fmt.Sprintf("hrs_%s_%d", id, i+1), Name: h.name, ClothNumber: h.cloth})
	}
	return r
}

func numberedField(names ...string) []numbered {
	var out []numbered
	for i, n := range names {
		out = append(out, numbered{n, ip(i + 1)})
	}
	return out
}

type sel struct {
	name   string
	cloth  *int
	active bool
}

func testMarket(id, venue string, start time.Time, selections ...sel) ExchangeMarket {
	m := ExchangeMarket{ID: id, Venue: venue, StartTime: start, MarketName: "1m Hcap"}
	for i, s := range selections {
		m.Runners = append(m.Runners, ExchangeRunner{ID: int64(10_000 + i + 1), Name: s.name, ClothNumber: s.cloth, IsActive: s.active})
	}
	return m
}

func numberedSelections(names ...string) []sel {
	var out []sel
	for i, n := range names {
		out = append(out, sel{n, ip(i + 1), true})
	}
	return out
}

var field = []string{"Kyprios", "Stradivarius", "Trueshan", "Pyledriver", "Hukum"}
var other = []string{"Baaeed", "Adayar", "Mishriff", "Alcohol Free", "Palace Pier"}

func race(horses ...string) domain.Race {
	return testRace("rac_1", "Newmarket", &baseOff, numberedField(horses...)...)
}

func market(id string, start time.Time, names ...string) ExchangeMarket {
	return testMarket(id, "Newmarket", start, numberedSelections(names...)...)
}

func near(a, b float64) bool { return math.Abs(a-b) < 1e-4 }

// MARK: - Course names

var allCourses = []string{
	"Aintree", "Ascot", "Ayr", "Bangor-on-Dee", "Bath", "Beverley", "Brighton",
	"Carlisle", "Cartmel", "Catterick Bridge", "Chelmsford City", "Cheltenham",
	"Chepstow", "Chester", "Doncaster", "Epsom Downs", "Exeter", "Fakenham",
	"Ffos Las", "Fontwell Park", "Goodwood", "Great Yarmouth", "Hamilton Park",
	"Haydock Park", "Hereford", "Hexham", "Huntingdon", "Kelso", "Kempton Park",
	"Leicester", "Lingfield Park", "Ludlow", "Market Rasen", "Musselburgh",
	"Newbury", "Newcastle", "Newmarket", "Newton Abbot", "Nottingham", "Perth",
	"Plumpton", "Pontefract", "Redcar", "Ripon", "Salisbury", "Sandown Park",
	"Sedgefield", "Southwell", "Stratford-on-Avon", "Taunton", "Thirsk",
	"Uttoxeter", "Warwick", "Wetherby", "Wincanton", "Windsor", "Wolverhampton",
	"Worcester", "York",
	"Ballinrobe", "Bellewstown", "Clonmel", "Cork", "Curragh", "Down Royal",
	"Downpatrick", "Dundalk", "Fairyhouse", "Galway", "Gowran Park",
	"Kilbeggan", "Killarney", "Laytown", "Leopardstown", "Limerick",
	"Listowel", "Naas", "Navan", "Punchestown", "Roscommon", "Sligo",
	"Thurles", "Tipperary", "Tramore", "Wexford",
}

// No course-normalisation rule is acceptable unless this still passes: a rule
// that collapsed two real courses would price one meeting off another's market.
func TestNoTwoRealCoursesShareAKey(t *testing.T) {
	seen := map[string]string{}
	for _, c := range allCourses {
		k := CourseKey(c)
		if k == "" {
			t.Fatalf("%s normalised to nothing", c)
		}
		if prev, ok := seen[k]; ok {
			t.Fatalf("%s and %s both normalise to %q", c, prev, k)
		}
		seen[k] = c
	}
}

func TestProviderSpellingsAgree(t *testing.T) {
	pairs := [][2]string{
		{"Catterick Bridge", "Catterick"}, {"Great Yarmouth", "Yarmouth"}, {"Epsom Downs", "Epsom"},
		{"Kempton Park", "Kempton"}, {"Chelmsford City", "Chelmsford"}, {"Bangor-on-Dee", "Bangor"},
		{"Stratford-on-Avon", "Stratford"}, {"The Curragh", "Curragh"}, {"Newmarket (July)", "Newmarket"},
		{"Wolverhampton (AW)", "Wolverhampton"}, {"Ascot Racecourse", "Ascot"}, {"MARKET RASEN", "Market Rasen"},
		{"Newton  Abbot", "newton abbot"},
	}
	for _, p := range pairs {
		if !CoursesMatch(p[0], p[1]) {
			t.Fatalf("%s vs %s: %q %q", p[0], p[1], CourseKey(p[0]), CourseKey(p[1]))
		}
	}
	if CourseKey("Down Royal") != "down royal" || CoursesMatch("Down Royal", "Downpatrick") {
		t.Fatal("Down Royal keeps both words")
	}
	if CourseKey("(AW)") != "" || CoursesMatch("", "") || CoursesMatch("(AW)", "(July)") {
		t.Fatal("empty keys never match")
	}
	if CourseKey("Park") != "park" || CourseKey("The") != "the" {
		t.Fatal("a name of only droppable words is not erased")
	}
}

func TestHorseKeys(t *testing.T) {
	cases := map[string]string{
		"Kyprios (IRE)": "KYPRIOS", "3. Kyprios": "KYPRIOS", "12) Kyprios": "KYPRIOS", "7 Kyprios": "KYPRIOS",
		"3. Kyprios (IRE)": "KYPRIOS", "99Problems": "99PROBLEMS", "Something (Reserve)": "SOMETHINGRESERVE",
		"(IRE)": "IRE", "4.": "4", "O’Brien's Pride": "OBRIENSPRIDE", "Jack-In-The-Box": "JACKINTHEBOX",
	}
	for raw, want := range cases {
		if got := HorseKey(raw); got != want {
			t.Fatalf("%q: got %q want %q", raw, got, want)
		}
	}
	distances := []struct {
		a, b  string
		limit int
		want  int
	}{
		{"KYPRIOS", "KYPRIOS", 2, 0}, {"KYPRIOS", "KYPRIO", 2, 1}, {"KYPRIOS", "KIPRIO", 2, 2},
		{"KYPRIOS", "STRADIVARIUS", 2, -1}, {"ABC", "XYZ", 2, -1}, {"AB", "ABCDE", 2, -1},
		{"AB", "ABCD", 2, 2}, {"", "", 2, 0}, {"", "AB", 2, 2}, {"", "ABC", 2, -1}, {"KYPRIOS", "KYPRIO", 0, -1},
	}
	for _, d := range distances {
		if got := NameDistance(d.a, d.b, d.limit); got != d.want {
			t.Fatalf("%s/%s: got %d want %d", d.a, d.b, got, d.want)
		}
	}
}

// MARK: - Runner matcher

func runners(entries ...numbered) []domain.Runner {
	var out []domain.Runner
	for i, e := range entries {
		out = append(out, domain.Runner{ID: fmt.Sprintf("hrs_%d", i+1), Name: e.name, ClothNumber: e.cloth})
	}
	return out
}

func selections(entries ...numbered) []ExchangeRunner {
	var out []ExchangeRunner
	for i, e := range entries {
		out = append(out, ExchangeRunner{ID: int64(100 + i + 1), Name: e.name, ClothNumber: e.cloth, IsActive: true})
	}
	return out
}

func allBasis(r RunnerMatch, b Basis) bool {
	for _, p := range r.Pairings {
		if p.Basis != b {
			return false
		}
	}
	return len(r.Pairings) > 0
}

func TestRunnerMatcher(t *testing.T) {
	r := MatchRunners(runners(numbered{"Kyprios", ip(1)}, numbered{"Stradivarius", ip(2)}), selections(numbered{"1. Kyprios (IRE)", ip(1)}, numbered{"2. Stradivarius (GB)", ip(2)}), DefaultTolerances, true)
	if len(r.Pairings) != 2 || !allBasis(r, ByClothNumber) || r.Overlap() != 1 {
		t.Fatal("cloth numbers despite decorated names")
	}
	r = MatchRunners(runners(numbered{"Kyprios", ip(1)}, numbered{"Stradivarius", ip(2)}), selections(numbered{"Stradivarius", ip(1)}, numbered{"Kyprios", ip(2)}), DefaultTolerances, true)
	if !allBasis(r, ByExactName) || r.Pairings[0].SelectionID != 102 {
		t.Fatal("a contradicted cloth number is refused and names win")
	}
	r = MatchRunners(runners(numbered{"Kyprios", ip(1)}), selections(numbered{"Unknown Runner", ip(1)}), DefaultTolerances, true)
	if r.Pairings[0].Basis != ByClothNumber {
		t.Fatal("uncontradicted cloth survives")
	}
	r = MatchRunners(runners(numbered{"Kyprios", ip(1)}), selections(numbered{"Kyprios", nil}), DefaultTolerances, true)
	if r.Pairings[0].Basis != ByExactName {
		t.Fatal("names carry the join")
	}
	r = MatchRunners(runners(numbered{"Kyprios", ip(1)}), selections(numbered{"Kyprios", ip(1)}, numbered{"Someone Else", ip(1)}), DefaultTolerances, true)
	if r.Pairings[0].Basis != ByExactName {
		t.Fatal("a duplicated cloth is not used")
	}
	r = MatchRunners(runners(numbered{"Kyprios", nil}), selections(numbered{"Kypriosa", nil}), DefaultTolerances, true)
	if r.Pairings[0].Basis != BySimilarName {
		t.Fatal("typo-sized difference")
	}
	r = MatchRunners(runners(numbered{"Misterman", nil}), selections(numbered{"Mistermen", nil}, numbered{"Mistermin", nil}), DefaultTolerances, true)
	if len(r.Pairings) != 0 {
		t.Fatal("a similarity tie is refused")
	}
	r = MatchRunners(runners(numbered{"Mistermen", nil}, numbered{"Mistermin", nil}), selections(numbered{"Misterman", nil}), DefaultTolerances, true)
	if len(r.Pairings) != 0 || len(r.UnmatchedHorseIDs) != 2 {
		t.Fatal("two runners competing for one selection are both refused")
	}
	strict := DefaultTolerances
	strict.MaximumNameDistance = 0
	if r = MatchRunners(runners(numbered{"Kyprios", nil}), selections(numbered{"Kypriosa", nil}), strict, true); len(r.Pairings) != 0 {
		t.Fatal("strict names")
	}
	r = MatchRunners(runners(numbered{"Kyprios", ip(1)}, numbered{"Kyprios", ip(2)}), selections(numbered{"Kyprios", ip(1)}), DefaultTolerances, true)
	if len(r.Pairings) > 1 {
		t.Fatal("no selection used twice")
	}
	r = MatchRunners(nil, selections(numbered{"Kyprios", ip(1)}), DefaultTolerances, true)
	if r.Overlap() != 0 || len(r.UnmatchedSelectionIDs) != 1 {
		t.Fatal("empty")
	}
}

// MARK: - Race matcher

func TestACardMatchesItsMarkets(t *testing.T) {
	rep := MatchRaces([]domain.Race{race(field...)}, []ExchangeMarket{market("1.100", baseOff, field...)}, DefaultTolerances)
	if len(rep.Matches) != 1 || rep.Matches[0].MarketID != "1.100" || rep.Matches[0].Runners.Overlap() != 1 || len(rep.Refusals) != 0 || len(rep.UnclaimedMarketIDs) != 0 {
		t.Fatalf("%+v", rep)
	}
	cat := testRace("rac_1", "Catterick Bridge", &baseOff, numberedField(field...)...)
	if n := len(MatchRaces([]domain.Race{cat}, []ExchangeMarket{testMarket("1.100", "Catterick", baseOff, numberedSelections(field...)...)}, DefaultTolerances).Matches); n != 1 {
		t.Fatal("course spellings")
	}
}

func TestTimeWindow(t *testing.T) {
	for _, m := range []float64{5, -5} {
		rep := MatchRaces([]domain.Race{race(field...)}, []ExchangeMarket{market("1.100", at(m), field...)}, DefaultTolerances)
		if len(rep.Matches) != 1 || !near(rep.Matches[0].MinutesApart, 5) {
			t.Fatal("inside the window, both directions")
		}
	}
	rep := MatchRaces([]domain.Race{race(field...)}, []ExchangeMarket{market("1.100", at(7), field...)}, DefaultTolerances)
	if rep.Refusals["rac_1"].Kind != RefusedNoCandidate {
		t.Fatal("outside the window")
	}
}

func TestTwoMeetingsAtOneCourse(t *testing.T) {
	july := testRace("rac_july", "Newmarket (July)", &baseOff, numberedField(field...)...)
	rowley := testRace("rac_rowley", "Newmarket (Rowley Mile)", &baseOff, numberedField(other...)...)
	rep := MatchRaces([]domain.Race{july, rowley}, []ExchangeMarket{market("1.july", baseOff, field...), market("1.rowley", baseOff, other...)}, DefaultTolerances)
	got := map[string]string{}
	for _, m := range rep.Matches {
		got[m.RaceID] = m.MarketID
	}
	if got["rac_july"] != "1.july" || got["rac_rowley"] != "1.rowley" || len(rep.Refusals) != 0 {
		t.Fatalf("%+v", rep)
	}
}

// The worst thing this component can do, and the easiest to write by accident.
func TestClothNumbersAloneCannotIdentifyARace(t *testing.T) {
	rep := MatchRaces([]domain.Race{race(field...)}, []ExchangeMarket{market("1.100", baseOff, other...)}, DefaultTolerances)
	if len(rep.Matches) != 0 {
		t.Fatal("matched a different race on cloth numbers")
	}
	if r := rep.Refusals["rac_1"]; r.Kind != RefusedNoOverlap || r.MarketID != "1.100" || r.Overlap != 0 {
		t.Fatalf("%+v", r)
	}
	if len(rep.UnclaimedMarketIDs) != 1 {
		t.Fatal("unclaimed")
	}
}

func TestClothNumbersFillInOnceSettled(t *testing.T) {
	rep := MatchRaces([]domain.Race{race(field...)}, []ExchangeMarket{market("1.100", baseOff, "Kyprios", "Stradivarius", "Trueshan", "Pyledriver", "Hukum The Second")}, DefaultTolerances)
	m := rep.Matches[0]
	if !near(m.NameEvidence, 0.8) || m.Runners.Overlap() != 1 {
		t.Fatalf("%+v", m)
	}
	for _, p := range m.Runners.Pairings {
		if p.HorseID == "hrs_rac_1_5" && p.Basis != ByClothNumber {
			t.Fatal("the fifth runner should join on cloth")
		}
	}
}

func TestOverlapThresholdTiesAndClaims(t *testing.T) {
	if n := len(MatchRaces([]domain.Race{race(field...)}, []ExchangeMarket{market("1.100", baseOff, "Kyprios", "Stradivarius", "Trueshan", "Stranger", "Another")}, DefaultTolerances).Matches); n != 1 {
		t.Fatal("60% is enough")
	}
	rep := MatchRaces([]domain.Race{race(field...)}, []ExchangeMarket{market("1.100", baseOff, "Kyprios", "Stradivarius", "Stranger", "Another", "AndAnother")}, DefaultTolerances)
	if r := rep.Refusals["rac_1"]; r.Kind != RefusedNoOverlap || !near(r.Overlap, 0.4) {
		t.Fatalf("%+v", r)
	}
	rep = MatchRaces([]domain.Race{race(field...)}, []ExchangeMarket{market("1.a", baseOff, field...), market("1.b", baseOff, field...)}, DefaultTolerances)
	if r := rep.Refusals["rac_1"]; r.Kind != RefusedAmbiguous || r.MarketIDs[0] != "1.a" || r.MarketIDs[1] != "1.b" {
		t.Fatal("an unbreakable tie is refused")
	}
	rep = MatchRaces([]domain.Race{race(field...)}, []ExchangeMarket{market("1.near", at(1), field...), market("1.far", at(5), field...)}, DefaultTolerances)
	if rep.Matches[0].MarketID != "1.near" || rep.UnclaimedMarketIDs[0] != "1.far" {
		t.Fatal("time breaks a tie")
	}
	rep = MatchRaces([]domain.Race{race(field...)}, []ExchangeMarket{market("1.wrong", at(0), other...), market("1.right", at(3), field...)}, DefaultTolerances)
	if rep.Matches[0].MarketID != "1.right" {
		t.Fatal("runners outrank the clock")
	}
	big := testRace("rac_big", "Newmarket", &baseOff, numberedField(field...)...)
	small := testRace("rac_small", "Newmarket", &baseOff, numberedField("Kyprios", "Stradivarius", "Trueshan")...)
	rep = MatchRaces([]domain.Race{small, big}, []ExchangeMarket{market("1.100", baseOff, field...)}, DefaultTolerances)
	if len(rep.Matches) != 1 || rep.Matches[0].RaceID != "rac_big" {
		t.Fatal("a market is claimed once, by the bigger field")
	}
}

func TestRefusalsCarryReasons(t *testing.T) {
	withdrawn := testMarket("1.100", "Newmarket", baseOff, sel{"Kyprios", ip(1), true}, sel{"Stradivarius", ip(2), true}, sel{"Withdrawn", ip(3), false})
	rep := MatchRaces([]domain.Race{race("Kyprios", "Stradivarius")}, []ExchangeMarket{withdrawn}, DefaultTolerances)
	if rep.Matches[0].Runners.Overlap() != 1 || len(rep.Matches[0].Runners.UnmatchedSelectionIDs) != 0 {
		t.Fatal("removed selections do not count")
	}
	if rep := MatchRaces([]domain.Race{testRace("rac_1", "Newmarket", nil, numberedField(field...)...)}, []ExchangeMarket{market("1.100", baseOff, field...)}, DefaultTolerances); rep.Refusals["rac_1"].Kind != RefusedNoOffTime {
		t.Fatal("no off time")
	}
	if rep := MatchRaces([]domain.Race{race()}, []ExchangeMarket{market("1.100", baseOff, field...)}, DefaultTolerances); rep.Refusals["rac_1"].Kind != RefusedNoRunners {
		t.Fatal("no runners")
	}
	perth := testRace("rac_1", "Perth", &baseOff, numberedField(field...)...)
	if rep := MatchRaces([]domain.Race{perth}, []ExchangeMarket{market("1.100", baseOff, field...)}, DefaultTolerances); rep.Refusals["rac_1"].Kind != RefusedNoCandidate {
		t.Fatal("no market at the course")
	}
}

func TestSnapshotDropsUnmatchedSelections(t *testing.T) {
	m := Match{MarketID: "1.1", Runners: RunnerMatch{Pairings: []Pairing{{HorseID: "a", SelectionID: 1}}}}
	b := 2.0
	snap := Snapshot(ExchangePrices{MarketID: "1.1", Prices: map[int64]domain.RunnerPrice{1: {BackPrice: &b, IsActive: true}, 2: {BackPrice: &b, IsActive: true}}}, m.HorseIDsBySelectionID(), domain.SourceLiveExchange)
	if len(snap.Prices) != 1 || snap.Prices["a"].BackPrice == nil {
		t.Fatal("an unmatched selection's price must be dropped")
	}
	ref := m.Reference()
	if sps := ref.StartingPrices(map[string]map[int64]float64{"1.1": {1: 4.5}, "1.2": {1: 9}}); sps["a"] != 4.5 || len(sps) != 1 {
		t.Fatal(sps)
	}
	if sps := ref.StartingPrices(map[string]map[int64]float64{"1.1": {1: 1.0}}); len(sps) != 0 {
		t.Fatal("a price of 1 is not a price")
	}
}
