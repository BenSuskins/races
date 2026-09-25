// Package rating is the model: factors, form scoring, the market anchor and the
// rater that combines them. Everything here is pure — no network, no clock, no
// disk — which is what lets the back-test replay history in seconds.
//
// It is a line-for-line port of RacesKit/Rating. The numbers and the strings
// are the same on purpose: a tip's contributions are stored and shown, and a
// model that behaved differently here from on the device would split the
// accuracy history without saying so.
package rating

import (
	"encoding/json"
	"fmt"

	"github.com/bensuskins/races/server/internal/domain"
)

// FactorID is stable: it is stamped into stored tips.
type FactorID string

const (
	OfficialRating       FactorID = "officialRating"
	HandicapBandPosition FactorID = "handicapBandPosition"
	RecentForm           FactorID = "recentForm"
	WonLastTime          FactorID = "wonLastTime"
	CompletionRate       FactorID = "completionRate"
	DaysSinceLastRun     FactorID = "daysSinceLastRun"
	Age                  FactorID = "age"
	WeightCarried        FactorID = "weightCarried"
	Draw                 FactorID = "draw"
	Headgear             FactorID = "headgear"
	JockeyStrikeRate     FactorID = "jockeyStrikeRate"
	TrainerStrikeRate    FactorID = "trainerStrikeRate"
	HorseGoingPlaceRate  FactorID = "horseGoingPlaceRate"
)

// AllFactors in declaration order, which is also the rater's order.
var AllFactors = []FactorID{
	OfficialRating, HandicapBandPosition, RecentForm, WonLastTime, CompletionRate,
	DaysSinceLastRun, Age, WeightCarried, Draw, Headgear, JockeyStrikeRate, TrainerStrikeRate, HorseGoingPlaceRate,
}

// Label is the short name shown on screen.
func (f FactorID) Label() string {
	switch f {
	case OfficialRating:
		return "Official rating"
	case HandicapBandPosition:
		return "Position in the handicap"
	case RecentForm:
		return "Recent form"
	case WonLastTime:
		return "Won last time out"
	case CompletionRate:
		return "Completion record"
	case DaysSinceLastRun:
		return "Days since last run"
	case Age:
		return "Age"
	case WeightCarried:
		return "Weight carried"
	case Draw:
		return "Draw"
	case Headgear:
		return "Headgear"
	case JockeyStrikeRate:
		return "Jockey strike rate"
	case TrainerStrikeRate:
		return "Trainer strike rate"
	case HorseGoingPlaceRate:
		return "Horse record by going"
	}
	return string(f)
}

// Summary is one sentence on what the factor reads.
func (f FactorID) Summary() string {
	switch f {
	case OfficialRating:
		return "The handicapper's number. The strongest thing the free tier gives us."
	case HandicapBandPosition:
		return "Where the rating sits inside the race's own band — well in at the top, struggling at the bottom."
	case RecentForm:
		return "The form string, read right to left and weighted toward the most recent run."
	case WonLastTime:
		return "Whether the last completed run was a win."
	case CompletionRate:
		return "How often the horse finishes at all. It means far more over fences than on the Flat."
	case DaysSinceLastRun:
		return "Time off, scored as a bell rather than a line — a fortnight is better than three days or three months."
	case Age:
		return "Age against the race's own age band."
	case WeightCarried:
		return "Pounds carried, negated so less is better."
	case Draw:
		return "Stall number."
	case Headgear:
		return "Blinkers, a visor, a hood, cheekpieces."
	case JockeyStrikeRate:
		return "The jockey's win rate in the server's own archive, shrunk toward the field average."
	case TrainerStrikeRate:
		return "The trainer's win rate in the server's own archive, shrunk toward the field average."
	case HorseGoingPlaceRate:
		return "The horse's place rate on similar ground, shrunk toward its general record."
	}
	return ""
}

// Rationale explains the weight — and for the factors at zero, why the code is
// present and switched off.
func (f FactorID) Rationale() string {
	switch f {
	case Draw:
		return "Draw bias is real, but it is a course × distance × going × field-size interaction. Without a bias table it is noise, so the code ships switched off."
	case Headgear:
		return "The signal is *first-time* headgear, and the free tier has no headgear history to detect it with."
	case JockeyStrikeRate, TrainerStrikeRate:
		return "Legitimate, but derived from an archive that starts empty. It switches on once enough race days have been collected."
	case HorseGoingPlaceRate:
		return "The archive needs at least three completed runs in a going bucket. Its default weight is zero until replay supports it."
	case WeightCarried:
		return "Near zero on purpose: in a handicap, weight is the handicapper's equaliser, so it substantially double-counts the official rating."
	}
	return ""
}

// Availability says why a factor produced no value. "We don't know", "this
// doesn't apply" and "your plan doesn't include this" are three different
// sentences, and none is an error.
type Availability struct {
	Kind   string // available, missingData, notApplicable, requiresPaidTier
	Reason string
}

const (
	Available        = "available"
	MissingData      = "missingData"
	NotApplicable    = "notApplicable"
	RequiresPaidTier = "requiresPaidTier"
)

func (a Availability) IsAvailable() bool { return a.Kind == Available }

// MarshalJSON writes Swift's synthesised shape: {"available":{}} or
// {"missingData":{"_0":"reason"}}.
func (a Availability) MarshalJSON() ([]byte, error) {
	if a.Kind == Available || a.Kind == "" {
		return []byte(`{"available":{}}`), nil
	}
	return json.Marshal(map[string]map[string]string{a.Kind: {"_0": a.Reason}})
}

func (a *Availability) UnmarshalJSON(data []byte) error {
	var wrapper map[string]struct {
		Reason string `json:"_0"`
	}
	if err := json.Unmarshal(data, &wrapper); err != nil {
		return err
	}
	for kind, body := range wrapper {
		a.Kind, a.Reason = kind, body.Reason
		return nil
	}
	return fmt.Errorf("availability: empty object")
}

// FactorValue is one factor's raw reading for one runner. Higher is always
// better; factors where less is more negate at source.
type FactorValue struct {
	Raw          *float64
	Display      string
	Availability Availability
}

func value(raw float64, display string) FactorValue {
	return FactorValue{Raw: &raw, Display: display, Availability: Availability{Kind: Available}}
}

func missing(reason string, display ...string) FactorValue {
	return FactorValue{Display: orDash(display), Availability: Availability{MissingData, reason}}
}

func notApplicable(reason string, display ...string) FactorValue {
	return FactorValue{Display: orDash(display), Availability: Availability{NotApplicable, reason}}
}

func requiresPaidTier(reason string, display ...string) FactorValue {
	return FactorValue{Display: orDash(display), Availability: Availability{RequiresPaidTier, reason}}
}

func orDash(display []string) string {
	if len(display) > 0 {
		return display[0]
	}
	return "—"
}

// StrikeRate is a win record from the server's own results archive.
type StrikeRate struct {
	Runs int `json:"runs"`
	Wins int `json:"wins"`
}

// Smoothed shrinks the record toward a prior, so one win from one run is not a
// 100% strike rate. strength is the number of notional prior runs.
func (s StrikeRate) Smoothed(prior, strength float64) float64 {
	total := float64(s.Runs) + strength
	if total <= 0 {
		return prior
	}
	return (float64(s.Wins) + prior*strength) / total
}

// StrikeRates supplies jockey and trainer records.
type StrikeRates interface {
	JockeyStrikeRate(id string) (StrikeRate, bool)
	TrainerStrikeRate(id string) (StrikeRate, bool)
	BaselineStrikeRate() float64
}

type PlaceRate struct {
	Runs   int `json:"runs"`
	Places int `json:"places"`
}

func (r PlaceRate) Smoothed(prior float64, strength float64) float64 {
	return (float64(r.Places) + prior*strength) / (float64(r.Runs) + strength)
}

type HorseGoingProvider interface {
	HorseGoingRate(horseID string, surface domain.Surface, bucket domain.GoingBucket) (PlaceRate, bool)
	HorseOverallPlaceRate(horseID string) (PlaceRate, bool)
}

// Context is everything a factor may look at beyond the runner.
type Context struct {
	Race        domain.Race
	StrikeRates StrikeRates
}

// Factor is a single, independently testable input to the rating.
type Factor interface {
	ID() FactorID
	Value(runner domain.Runner, ctx Context) FactorValue
}
