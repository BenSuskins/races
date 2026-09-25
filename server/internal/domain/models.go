package domain

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Course is a racecourse.
type Course struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	RegionCode string `json:"regionCode"`
	Region     string `json:"region"`
}

// Runner is one horse declared in a race. nil means unknown, never zero: the
// rater treats unknown as race-neutral and zero as the worst in the field.
type Runner struct {
	ID               string  `json:"id"`
	Name             string  `json:"name"`
	ClothNumber      *int    `json:"clothNumber,omitempty"`
	Draw             *int    `json:"draw,omitempty"`
	Age              *int    `json:"age,omitempty"`
	Sex              *string `json:"sex,omitempty"`
	RegionCode       *string `json:"regionCode,omitempty"`
	OfficialRating   *int    `json:"officialRating,omitempty"`
	WeightPounds     *int    `json:"weightPounds,omitempty"`
	Headgear         *string `json:"headgear,omitempty"`
	Form             *string `json:"form,omitempty"`
	DaysSinceLastRun *int    `json:"daysSinceLastRun,omitempty"`
	JockeyID         *string `json:"jockeyID,omitempty"`
	JockeyName       *string `json:"jockeyName,omitempty"`
	TrainerID        *string `json:"trainerID,omitempty"`
	TrainerName      *string `json:"trainerName,omitempty"`
	OwnerName        *string `json:"ownerName,omitempty"`
	SireName         *string `json:"sireName,omitempty"`
	DamName          *string `json:"damName,omitempty"`
	RacingPostRating *int    `json:"racingPostRating,omitempty"`
	TopspeedRating   *int    `json:"topspeedRating,omitempty"`
	Spotlight        *string `json:"spotlight,omitempty"`
	SilkURL          *string `json:"silkURL,omitempty"`
}

// WeightDisplay is stones-and-pounds, e.g. "9-07".
func (r Runner) WeightDisplay() string {
	if r.WeightPounds == nil || *r.WeightPounds <= 0 {
		return ""
	}
	w := *r.WeightPounds
	return itoa(w/14) + "-" + pad2(w%14)
}

// Race is a race on a card.
type Race struct {
	ID          string       `json:"id"`
	CourseName  string       `json:"courseName"`
	CourseID    *string      `json:"courseID,omitempty"`
	Name        string       `json:"name"`
	OffTime     string       `json:"offTime"`
	OffDateTime *Instant     `json:"offDateTime,omitempty"`
	Date        string       `json:"date"`
	Distance    *Distance    `json:"distance,omitempty"`
	Going       Going        `json:"going"`
	Surface     Surface      `json:"surface"`
	Type        RaceType     `json:"type"`
	RaceClass   *int         `json:"raceClass,omitempty"`
	Pattern     *string      `json:"pattern,omitempty"`
	AgeBand     *string      `json:"ageBand,omitempty"`
	RatingBand  *ClosedRange `json:"ratingBand,omitempty"`
	Prize       *string      `json:"prize,omitempty"`
	FieldSize   *int         `json:"fieldSize,omitempty"`
	RegionCode  *string      `json:"regionCode,omitempty"`
	Status      *string      `json:"status,omitempty"`
	Runners     []Runner     `json:"runners"`
}

// IsHandicap is inferred from the title; the free tier has no flag, and in
// British racing naming a handicap as such is a condition of the race.
func (r Race) IsHandicap() bool {
	t := strings.ToLower(r.Name)
	return strings.Contains(t, "handicap") || strings.Contains(t, "h'cap") || strings.Contains(t, "hcap")
}

// DeclaredRunners is the field in racecard order: by cloth number, unnumbered
// runners last and by name.
func (r Race) DeclaredRunners() []Runner {
	out := append([]Runner(nil), r.Runners...)
	sort.SliceStable(out, func(i, j int) bool {
		l, rr := out[i].ClothNumber, out[j].ClothNumber
		switch {
		case l != nil && rr != nil:
			return *l < *rr
		case l == nil && rr != nil:
			return false
		case l != nil && rr == nil:
			return true
		default:
			return out[i].Name < out[j].Name
		}
	})
	return out
}

// Off is the off time, if known.
func (r Race) Off() (time.Time, bool) {
	if r.OffDateTime == nil {
		return time.Time{}, false
	}
	return r.OffDateTime.Time, true
}

// Finisher is one horse's outcome in a settled race.
type Finisher struct {
	HorseID              string         `json:"horseID"`
	HorseName            string         `json:"horseName"`
	Position             FinishPosition `json:"position"`
	ClothNumber          *int           `json:"clothNumber,omitempty"`
	Draw                 *int           `json:"draw,omitempty"`
	WeightPounds         *int           `json:"weightPounds,omitempty"`
	OfficialRating       *int           `json:"officialRating,omitempty"`
	JockeyID             *string        `json:"jockeyID,omitempty"`
	TrainerID            *string        `json:"trainerID,omitempty"`
	StartingPriceDecimal *float64       `json:"startingPriceDecimal,omitempty"`
}

// RaceResult is a settled race.
type RaceResult struct {
	ID          string     `json:"id"`
	CourseName  string     `json:"courseName"`
	Name        string     `json:"name"`
	Date        string     `json:"date"`
	OffDateTime *Instant   `json:"offDateTime,omitempty"`
	Distance    *Distance  `json:"distance,omitempty"`
	Going       Going      `json:"going"`
	Surface     Surface    `json:"surface"`
	Type        RaceType   `json:"type"`
	RaceClass   *int       `json:"raceClass,omitempty"`
	Finishers   []Finisher `json:"finishers"`
}

func (r RaceResult) Winner() *Finisher {
	for i := range r.Finishers {
		if r.Finishers[i].Position.IsWinner() {
			return &r.Finishers[i]
		}
	}
	return nil
}

func (r RaceResult) Finisher(horseID string) *Finisher {
	for i := range r.Finishers {
		if r.Finishers[i].HorseID == horseID {
			return &r.Finishers[i]
		}
	}
	return nil
}

// DidRun says whether a horse ran. Absence from a settled result means it was
// withdrawn — void, not beaten.
//
// Returns ok=false below three finishers: a truncated payload would otherwise
// settle every runner as a non-runner and wipe a day of tips in one pass.
func (r RaceResult) DidRun(horseID string) (ran bool, ok bool) {
	if len(r.Finishers) < 3 {
		return false, false
	}
	return r.Finisher(horseID) != nil, true
}

// RunnerPrice is one runner's exchange prices.
type RunnerPrice struct {
	BackPrice     *float64 `json:"backPrice,omitempty"`
	LayPrice      *float64 `json:"layPrice,omitempty"`
	LastTraded    *float64 `json:"lastTraded,omitempty"`
	ForecastPrice *float64 `json:"forecastPrice,omitempty"`
	IsActive      bool     `json:"isActive"`
}

func (p RunnerPrice) HasAnyPrice() bool {
	return p.BackPrice != nil || p.LayPrice != nil || p.LastTraded != nil || p.ForecastPrice != nil
}

// MarketSource is where a snapshot's prices came from.
type MarketSource string

const (
	SourceLiveExchange MarketSource = "liveExchange"
	SourceForecast     MarketSource = "forecast"
)

// MarketSnapshot is the market's view of one race, keyed by *our* horse id.
// Matching happens before this is built, so the rater never learns that two
// providers exist.
type MarketSnapshot struct {
	MarketID            *string                `json:"marketID,omitempty"`
	Source              MarketSource           `json:"source"`
	CapturedAt          Instant                `json:"capturedAt"`
	IsDelayed           bool                   `json:"isDelayed"`
	Prices              map[string]RunnerPrice `json:"prices"`
	FirstObservedAt     *Instant               `json:"firstObservedAt,omitempty"`
	FirstObservedPrices map[string]RunnerPrice `json:"firstObservedPrices,omitempty"`
}

func (m MarketSnapshot) Price(horseID string) (RunnerPrice, bool) {
	p, ok := m.Prices[horseID]
	return p, ok
}

// Coverage is the share of a field with a usable price.
func (m MarketSnapshot) Coverage(runners []Runner) float64 {
	if len(runners) == 0 {
		return 0
	}
	priced := 0
	for _, r := range runners {
		if p, ok := m.Prices[r.ID]; ok && p.HasAnyPrice() {
			priced++
		}
	}
	return float64(priced) / float64(len(runners))
}

func itoa(n int) string { return strconv.Itoa(n) }

func pad2(n int) string { return fmt.Sprintf("%02d", n) }

// MarketReference is where a race sat on the exchange, frozen onto a tip when
// the match was made so a settled starting price can be found long after the
// catalogue that produced it has gone.
//
// Keyed our id → theirs so the stored JSON is an object a person can read. It
// holds the whole field, not just the selection: the favourite baseline needs a
// price too, and a priced tip against a priceless benchmark is the most
// flattering asymmetry possible.
type MarketReference struct {
	MarketID              string           `json:"marketID"`
	SelectionIDsByHorseID map[string]int64 `json:"selectionIDsByHorseID"`
}

// StartingPrices re-keys Betfair's settled prices ([marketID][selectionID])
// onto our horse ids, dropping anything it cannot place or that is not above 1.
func (m MarketReference) StartingPrices(settled map[string]map[int64]float64) map[string]float64 {
	out := map[string]float64{}
	bySelection, ok := settled[m.MarketID]
	if !ok {
		return out
	}
	for horseID, selectionID := range m.SelectionIDsByHorseID {
		if price, ok := bySelection[selectionID]; ok && price > 1 {
			out[horseID] = price
		}
	}
	return out
}
