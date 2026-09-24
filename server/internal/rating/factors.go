package rating

import (
	"fmt"
	"math"
	"strings"

	"github.com/bensuskins/races/server/internal/domain"
)

type officialRating struct{}

func (officialRating) ID() FactorID { return OfficialRating }
func (officialRating) Value(r domain.Runner, _ Context) FactorValue {
	if r.OfficialRating == nil {
		return missing("no official rating", "Unrated")
	}
	return value(float64(*r.OfficialRating), fmt.Sprintf("OR %d", *r.OfficialRating))
}

// handicapBandPosition is where a runner sits inside the band the race is
// framed for: 95 is top weight in a 0-95 and mid-division in a 0-110.
type handicapBandPosition struct{}

func (handicapBandPosition) ID() FactorID { return HandicapBandPosition }
func (handicapBandPosition) Value(r domain.Runner, ctx Context) FactorValue {
	if !ctx.Race.IsHandicap() {
		return notApplicable("not a handicap")
	}
	band := ctx.Race.RatingBand
	if band == nil || band.Upper <= band.Lower {
		return notApplicable("no rating band published")
	}
	if r.OfficialRating == nil {
		return missing("no official rating", "Unrated")
	}
	span := float64(band.Upper - band.Lower)
	position := (float64(*r.OfficialRating) - float64(band.Lower)) / span
	percent := int(math.Round(position * 100))
	return value(position, fmt.Sprintf("%d%% up the %d-%d band", percent, band.Lower, band.Upper))
}

type recentForm struct{ scorer FormScorer }

func (recentForm) ID() FactorID { return RecentForm }
func (f recentForm) Value(r domain.Runner, _ Context) FactorValue {
	line := ParseForm(r.Form)
	score := f.scorer.Score(line)
	if score == nil {
		return missing("no recorded form", "Unraced")
	}
	return value(*score, line.Raw)
}

type wonLastTime struct{}

func (wonLastTime) ID() FactorID { return WonLastTime }
func (wonLastTime) Value(r domain.Runner, _ Context) FactorValue {
	won := ParseForm(r.Form).WonLastTime()
	if won == nil {
		return missing("no recorded form", "Unraced")
	}
	if *won {
		return value(1, "Won last time")
	}
	return value(0, "Did not win last time")
}

// completionRate is real information over obstacles and close to none on the
// Flat, where almost everything finishes.
type completionRate struct{}

func (completionRate) ID() FactorID { return CompletionRate }
func (completionRate) Value(r domain.Runner, ctx Context) FactorValue {
	if !ctx.Race.Type.IsJumps() {
		return notApplicable("only meaningful over obstacles")
	}
	rate := ParseForm(r.Form).CompletionRate()
	if rate == nil {
		return missing("no recorded form", "Unraced")
	}
	return value(*rate, fmt.Sprintf("Completed %d%% of recent runs", int(math.Round(*rate*100))))
}

// daysSinceLastRun is a bell, not a line: a quick return and a long layoff are
// both mild negatives.
type daysSinceLastRun struct{}

func (daysSinceLastRun) ID() FactorID { return DaysSinceLastRun }
func (daysSinceLastRun) Value(r domain.Runner, _ Context) FactorValue {
	if r.DaysSinceLastRun == nil {
		return missing("no recorded previous run", "First run")
	}
	d := *r.DaysSinceLastRun
	return value(Freshness(d), fmt.Sprintf("%d days", d))
}

// Freshness is 0...1, peaking over the two-to-five-week window.
func Freshness(days int) float64 {
	switch {
	case days < 0:
		return 0.5
	case days < 7:
		return 0.55
	case days < 14:
		return 0.80
	case days < 36:
		return 1.00
	case days < 61:
		return 0.85
	case days < 121:
		return 0.60
	case days < 241:
		return 0.35
	}
	return 0.20
}

// age only where the race actually mixes ages.
type age struct{}

func (age) ID() FactorID { return Age }
func (age) Value(r domain.Runner, ctx Context) FactorValue {
	if ctx.Race.AgeBand == nil || !strings.Contains(*ctx.Race.AgeBand, "+") {
		return notApplicable("race is confined to one age group")
	}
	if r.Age == nil {
		return missing("age unknown")
	}
	peak := 4.5
	if ctx.Race.Type.IsJumps() {
		peak = 8
	}
	return value(-math.Abs(float64(*r.Age)-peak), fmt.Sprintf("%dyo", *r.Age))
}

// weightCarried is statistically dubious and shipped near zero on purpose: in a
// handicap weight is the handicapper's equaliser.
type weightCarried struct{}

func (weightCarried) ID() FactorID { return WeightCarried }
func (weightCarried) Value(r domain.Runner, _ Context) FactorValue {
	if r.WeightPounds == nil || *r.WeightPounds <= 0 {
		return missing("no weight published")
	}
	display := r.WeightDisplay()
	if display == "" {
		display = fmt.Sprintf("%d lb", *r.WeightPounds)
	}
	return value(-float64(*r.WeightPounds), display)
}

// draw is present but deliberately inert: there is no bias data to use.
type draw struct{}

func (draw) ID() FactorID { return Draw }
func (draw) Value(r domain.Runner, ctx Context) FactorValue {
	if ctx.Race.Type != domain.RaceTypeFlat {
		return notApplicable("the draw doesn't apply over obstacles")
	}
	if r.Draw == nil {
		return missing("no draw published")
	}
	return notApplicable("no draw-bias data for this course yet", fmt.Sprintf("Stall %d", *r.Draw))
}

// headgear is inert: the signal is first-time headgear, which needs history.
type headgear struct{}

func (headgear) ID() FactorID { return Headgear }
func (headgear) Value(r domain.Runner, _ Context) FactorValue {
	display := "No headgear"
	if r.Headgear != nil {
		display = "Wearing " + *r.Headgear
	}
	return requiresPaidTier("first-time headgear needs a headgear history", display)
}

// strikeRate reads the server's own archive, silent until the sample is worth
// consulting and shrunk toward the field mean even then.
type strikeRate struct {
	jockey        bool
	minimumSample int
}

func (s strikeRate) ID() FactorID {
	if s.jockey {
		return JockeyStrikeRate
	}
	return TrainerStrikeRate
}

func (s strikeRate) Value(r domain.Runner, ctx Context) FactorValue {
	if ctx.StrikeRates == nil {
		return missing("no results archive yet")
	}
	subject := r.TrainerID
	if s.jockey {
		subject = r.JockeyID
	}
	if subject == nil {
		return missing("not identified")
	}
	var record StrikeRate
	var ok bool
	if s.jockey {
		record, ok = ctx.StrikeRates.JockeyStrikeRate(*subject)
	} else {
		record, ok = ctx.StrikeRates.TrainerStrikeRate(*subject)
	}
	if !ok {
		return missing("no record in the archive yet")
	}
	if record.Runs < s.minimumSample {
		return missing(fmt.Sprintf("only %d runs recorded so far", record.Runs))
	}
	smoothed := record.Smoothed(ctx.StrikeRates.BaselineStrikeRate(), 20)
	return value(smoothed, fmt.Sprintf("%d%% from %d runs", int(math.Round(smoothed*100)), record.Runs))
}

// DefaultFactors in the order the rater reads them.
func DefaultFactors(w Weights) []Factor {
	return []Factor{
		officialRating{}, handicapBandPosition{}, recentForm{scorer: w.Scorer()}, wonLastTime{},
		completionRate{}, daysSinceLastRun{}, age{}, weightCarried{}, draw{}, headgear{},
		strikeRate{jockey: true, minimumSample: w.MinimumStrikeRateSample},
		strikeRate{jockey: false, minimumSample: w.MinimumStrikeRateSample},
	}
}
