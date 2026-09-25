package domain

import (
	"encoding/json"
	"testing"
	"time"
)

func mustTime(t *testing.T, raw string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func londonTime(v time.Time) string { return v.In(London).Format("2006-01-02 15:04") }

func TestDayStringUsesLondonNotUTC(t *testing.T) {
	// 23:30 UTC in July is 00:30 the next day in London.
	if got := DayString(mustTime(t, "2026-07-15T23:30:00Z")); got != "2026-07-16" {
		t.Fatalf("got %s", got)
	}
}

func TestDayStringForRaceDay(t *testing.T) {
	now := mustTime(t, "2026-09-30T12:00:00Z")
	if DayStringFor(Today, now) != "2026-09-30" || DayStringFor(Tomorrow, now) != "2026-10-01" {
		t.Fatal("tomorrow must cross the month end")
	}
}

func TestDayMatchingCoversOnlyTwoDays(t *testing.T) {
	now := mustTime(t, "2026-09-20T12:00:00Z")
	for day, want := range map[string]RaceDay{"2026-09-20": Today, "2026-09-21": Tomorrow} {
		if got, ok := DayMatching(day, now); !ok || got != want {
			t.Fatalf("%s: got %v", day, got)
		}
	}
	for _, day := range []string{"2026-09-22", "2026-09-19", ""} {
		if _, ok := DayMatching(day, now); ok {
			t.Fatalf("%s should not match", day)
		}
	}
}

func TestParseTimestampFormats(t *testing.T) {
	for _, raw := range []string{"2026-09-20T14:30:00+01:00", "2026-09-20T14:30:00Z", "2026-09-20T14:30:00.123Z", "2026-09-20 14:30:00", "2026-09-20T14:30:00"} {
		if _, ok := ParseTimestamp(raw); !ok {
			t.Fatalf("%s did not parse", raw)
		}
	}
	for _, raw := range []string{"", "half past two"} {
		if _, ok := ParseTimestamp(raw); ok {
			t.Fatalf("%q parsed", raw)
		}
	}
	v, _ := ParseTimestamp("2026-09-20T14:30:00+01:00")
	if londonTime(v) != "2026-09-20 14:30" {
		t.Fatal(londonTime(v))
	}
}

func TestCombineReadsAfternoonTimesAsPM(t *testing.T) {
	cases := map[string]string{"3:05": "2026-09-20 15:05", "6:30": "2026-09-20 18:30", "14:30": "2026-09-20 14:30"}
	for off, want := range cases {
		v, ok := Combine("2026-09-20", off)
		if !ok || londonTime(v) != want {
			t.Fatalf("%s: got %s", off, londonTime(v))
		}
	}
	for _, c := range [][2]string{{"2026-09-20", "nonsense"}, {"2026-09-20", "1430"}, {"not-a-date", "14:30"}} {
		if _, ok := Combine(c[0], c[1]); ok {
			t.Fatalf("%v should be rejected", c)
		}
	}
}

func TestGoingParsesProviderStrings(t *testing.T) {
	cases := map[string]Going{
		"Good": GoingGood, "GD": GoingGood, "Good To Soft": GoingGoodToSoft, "Gd-Sft": GoingGoodToSoft,
		"Good To Firm": GoingGoodToFirm, "Heavy": GoingHeavy, "Standard To Slow": GoingStandardToSlow,
		"Fast": GoingFast, "": GoingUnknown, "Yielding to Soft": GoingUnknown,
	}
	for raw, want := range cases {
		if got := ParseGoing(raw); got != want {
			t.Fatalf("%q: got %s want %s", raw, got, want)
		}
	}
}

func TestSurfaceAndRaceType(t *testing.T) {
	if ParseSurface("All Weather") != SurfaceAllWeather || ParseSurface("Tapeta") != SurfaceAllWeather || ParseSurface("Moon dust") != SurfaceUnknown {
		t.Fatal("surface")
	}
	if ParseRaceType("NH Flat") != RaceTypeNationalHuntFlat || ParseRaceType("Bumper") != RaceTypeNationalHuntFlat {
		t.Fatal("race type")
	}
	if RaceTypeNationalHuntFlat.IsJumps() || !RaceTypeChase.IsJumps() {
		t.Fatal("a bumper has no obstacles")
	}
}

func TestFinishPosition(t *testing.T) {
	s := func(v string) *string { return &v }
	if p := ParseFinishPosition(s("1")); !p.IsWinner() {
		t.Fatal("1 wins")
	}
	if p := ParseFinishPosition(s("pu")); p.Kind != PositionPulledUp || p.DidComplete() || p.NumericPosition() != nil {
		t.Fatal("PU")
	}
	if p := ParseFinishPosition(s("WTF")); p.Kind != PositionOther || p.Raw != "WTF" {
		t.Fatal("unknown kept verbatim")
	}
}

// The wire shape Swift's synthesised Codable uses for enums with associated
// values. If this changes, every device upload and every app decode breaks.
func TestFinishPositionMatchesSwiftCodable(t *testing.T) {
	cases := map[string]FinishPosition{
		`{"finished":{"_0":3}}`: Finished(3),
		`{"pulledUp":{}}`:       {Kind: PositionPulledUp},
		`{"other":{"_0":"X"}}`:  {Kind: PositionOther, Raw: "X"},
	}
	for wire, value := range cases {
		out, _ := json.Marshal(value)
		if string(out) != wire {
			t.Fatalf("marshal: got %s want %s", out, wire)
		}
		var back FinishPosition
		if err := json.Unmarshal([]byte(wire), &back); err != nil || back != value {
			t.Fatalf("unmarshal %s: %+v %v", wire, back, err)
		}
	}
}

func TestInstantEncodesWholeSecondsUTC(t *testing.T) {
	v := At(time.Date(2026, 9, 20, 14, 30, 0, 123456789, London))
	out, _ := json.Marshal(v)
	if string(out) != `"2026-09-20T13:30:00Z"` {
		t.Fatalf("got %s — Swift's .iso8601 decoder rejects fractions", out)
	}
}

func TestRangeEncodesAsPair(t *testing.T) {
	out, _ := json.Marshal(ClosedRange{0, 85})
	if string(out) != `[0,85]` {
		t.Fatal(string(out))
	}
}

func TestDidRunGuardsShortFields(t *testing.T) {
	r := RaceResult{Finishers: []Finisher{{HorseID: "a"}, {HorseID: "b"}}}
	if _, ok := r.DidRun("c"); ok {
		t.Fatal("two finishers must not settle anything")
	}
	r.Finishers = append(r.Finishers, Finisher{HorseID: "d"})
	if ran, ok := r.DidRun("c"); !ok || ran {
		t.Fatal("c is a non-runner")
	}
}

func TestDeclaredRunnersOrder(t *testing.T) {
	two, one := 2, 1
	r := Race{Runners: []Runner{{ID: "z", Name: "Zed"}, {ID: "b", ClothNumber: &two}, {ID: "a", ClothNumber: &one}, {ID: "y", Name: "Alpha"}}}
	got := ""
	for _, x := range r.DeclaredRunners() {
		got += x.ID
	}
	if got != "abyz" {
		t.Fatal(got)
	}
}

func TestDrawBiasCellKeyUsesBroadComparableGroups(t *testing.T) {
	distance := &Distance{Furlongs: 5}
	key, ok := DrawBiasCellKey(" Ascot ", distance, SurfaceTurf, GoingGood, 12, 2)
	if !ok || key != "ascot|turf|sprint|good|9-12|inside" {
		t.Fatalf("unexpected draw context %q, %v", key, ok)
	}
	if _, ok := DrawBiasCellKey("Ascot", distance, SurfaceTurf, GoingUnknown, 12, 2); ok {
		t.Fatal("unknown going must not produce a comparable cell")
	}
	if _, ok := DrawBiasCellKey("Ascot", distance, SurfaceTurf, GoingGood, 12, 13); ok {
		t.Fatal("a draw outside the field must not produce a cell")
	}
}
