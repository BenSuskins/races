package rating

import (
	"math"
	"strings"
	"unicode"
)

// FormOutcome is one character of a form string.
type FormOutcome struct {
	Kind     string // finished, pulledUp, …, seasonBreak, longBreak, unrecognised
	Position int    // finished only; 0 in the string is stored as 10
	Char     rune   // unrecognised only
}

const (
	formFinished      = "finished"
	formPulledUp      = "pulledUp"
	formUnseatedRider = "unseatedRider"
	formFell          = "fell"
	formRefused       = "refused"
	formBroughtDown   = "broughtDown"
	formSlippedUp     = "slippedUp"
	formDisqualified  = "disqualified"
	formVoided        = "voided"
	formSeasonBreak   = "seasonBreak"
	formLongBreak     = "longBreak"
	formUnrecognised  = "unrecognised"
)

func (o FormOutcome) didComplete() bool { return o.Kind == formFinished }
func (o FormOutcome) isWin() bool       { return o.Kind == formFinished && o.Position == 1 }
func (o FormOutcome) isRun() bool {
	return o.Kind != formSeasonBreak && o.Kind != formLongBreak && o.Kind != formUnrecognised
}

// FormLine is a parsed form string, oldest first.
//
// UK convention puts the most recent run on the RIGHT: `1-3241` means the last
// run was a win. Reversing that would silently invert the strongest form signal
// the free tier has.
type FormLine struct {
	Raw      string
	Outcomes []FormOutcome
}

func (l FormLine) runs() []FormOutcome {
	var out []FormOutcome
	for _, o := range l.Outcomes {
		if o.isRun() {
			out = append(out, o)
		}
	}
	return out
}

// WonLastTime is nil for a horse that has never run.
func (l FormLine) WonLastTime() *bool {
	runs := l.runs()
	if len(runs) == 0 {
		return nil
	}
	won := runs[len(runs)-1].isWin()
	return &won
}

// CompletionRate is completed runs over all runs, or nil with no runs.
func (l FormLine) CompletionRate() *float64 {
	runs := l.runs()
	if len(runs) == 0 {
		return nil
	}
	completed := 0
	for _, r := range runs {
		if r.didComplete() {
			completed++
		}
	}
	rate := float64(completed) / float64(len(runs))
	return &rate
}

// ParseForm is total: it never rejects a string, and anything unrecognised is
// kept as such rather than costing us the racecard.
func ParseForm(raw *string) FormLine {
	if raw == nil {
		return FormLine{}
	}
	trimmed := strings.TrimSpace(*raw)
	if trimmed == "" {
		return FormLine{}
	}
	var outcomes []FormOutcome
	for _, c := range trimmed {
		if o, ok := formOutcome(c); ok {
			outcomes = append(outcomes, o)
		}
	}
	return FormLine{Raw: trimmed, Outcomes: outcomes}
}

func formOutcome(c rune) (FormOutcome, bool) {
	if c >= '0' && c <= '9' {
		n := int(c - '0')
		if n == 0 {
			n = 10 // '0' means tenth or worse, not position zero
		}
		return FormOutcome{Kind: formFinished, Position: n}, true
	}
	switch unicode.ToUpper(c) {
	case '-':
		return FormOutcome{Kind: formSeasonBreak}, true
	case '/':
		return FormOutcome{Kind: formLongBreak}, true
	case 'P':
		return FormOutcome{Kind: formPulledUp}, true
	case 'U':
		return FormOutcome{Kind: formUnseatedRider}, true
	case 'F':
		return FormOutcome{Kind: formFell}, true
	case 'R':
		return FormOutcome{Kind: formRefused}, true
	case 'B':
		return FormOutcome{Kind: formBroughtDown}, true
	case 'S':
		return FormOutcome{Kind: formSlippedUp}, true
	case 'D':
		return FormOutcome{Kind: formDisqualified}, true
	case 'V':
		return FormOutcome{Kind: formVoided}, true
	case ' ', ',':
		return FormOutcome{}, false
	}
	return FormOutcome{Kind: formUnrecognised, Char: c}, true
}

// DefaultFormPoints are hand-chosen, not fitted.
func DefaultFormPoints() map[string]float64 {
	return map[string]float64{
		"1": 1.00, "2": 0.72, "3": 0.55, "4": 0.42, "5": 0.32,
		"6": 0.25, "7": 0.20, "8": 0.16, "9": 0.13,
		"tenOrWorse":    0.05,
		"nonCompletion": 0.00,
	}
}

// FormScorer turns a form line into a number in 0...1.
type FormScorer struct {
	Points             map[string]float64
	Decay              float64
	SeasonBreakPenalty float64
	LongBreakPenalty   float64
	MaxRuns            int
}

// DefaultFormScorer matches FormScorer() in Swift.
func DefaultFormScorer() FormScorer {
	return FormScorer{Points: DefaultFormPoints(), Decay: 0.75, SeasonBreakPenalty: 0.80, LongBreakPenalty: 0.50, MaxRuns: 6}
}

func formTag(o FormOutcome) (string, bool) {
	switch o.Kind {
	case formFinished:
		if o.Position >= 10 {
			return "tenOrWorse", true
		}
		return string(rune('0' + o.Position)), true
	case formPulledUp, formUnseatedRider, formFell, formRefused, formBroughtDown, formSlippedUp, formDisqualified:
		return "nonCompletion", true
	}
	// A voided race tells us nothing about the horse.
	return "", false
}

// Score is the recency-weighted average of recent form, or nil with no runs.
func (s FormScorer) Score(line FormLine) *float64 {
	total, totalWeight := 0.0, 0.0
	index := 0
	breakMultiplier := 1.0

	for i := len(line.Outcomes) - 1; i >= 0; i-- {
		o := line.Outcomes[i]
		switch o.Kind {
		case formSeasonBreak:
			breakMultiplier *= s.SeasonBreakPenalty
			continue
		case formLongBreak:
			breakMultiplier *= s.LongBreakPenalty
			continue
		}
		tag, ok := formTag(o)
		if !ok {
			continue
		}
		if index >= s.MaxRuns {
			break
		}
		weight := math.Pow(s.Decay, float64(index)) * breakMultiplier
		total += weight * s.Points[tag]
		totalWeight += weight
		index++
	}
	if totalWeight <= 0 {
		return nil
	}
	v := total / totalWeight
	return &v
}
