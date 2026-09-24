package matching

import (
	"math"
	"sort"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
)

// ExchangeMarket is the exchange's view of one race before it is joined to
// ours. Provider-agnostic: a Betfair catalogue maps into it.
type ExchangeMarket struct {
	ID         string           `json:"id"`
	Venue      string           `json:"venue"`
	StartTime  time.Time        `json:"startTime"`
	MarketName string           `json:"marketName,omitempty"`
	Runners    []ExchangeRunner `json:"runners"`
}

// ActiveRunners excludes removed selections from matching entirely.
func (m ExchangeMarket) ActiveRunners() []ExchangeRunner {
	var out []ExchangeRunner
	for _, r := range m.Runners {
		if r.IsActive {
			out = append(out, r)
		}
	}
	return out
}

// ExchangeRunner is one selection.
type ExchangeRunner struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	ClothNumber *int   `json:"clothNumber,omitempty"`
	IsActive    bool   `json:"isActive"`
}

// Tolerances are every threshold the matcher uses.
type Tolerances struct {
	StartTimeWindowMinutes float64
	MinimumRunnerOverlap   float64
	MaximumNameDistance    int
}

// DefaultTolerances: six minutes (the providers disagree by more than two
// after a re-timed card), 60% name overlap, typo-sized fuzzy names.
var DefaultTolerances = Tolerances{StartTimeWindowMinutes: 6, MinimumRunnerOverlap: 0.6, MaximumNameDistance: 2}

// Basis is how a runner pairing was established.
type Basis string

const (
	ByClothNumber Basis = "clothNumber"
	ByExactName   Basis = "exactName"
	BySimilarName Basis = "similarName"
)

// Pairing is one runner joined to one selection.
type Pairing struct {
	HorseID     string `json:"horseID"`
	HorseName   string `json:"horseName"`
	SelectionID int64  `json:"selectionID"`
	Basis       Basis  `json:"basis"`
}

// RunnerMatch is one field joined to one market's selections.
type RunnerMatch struct {
	Pairings              []Pairing `json:"pairings"`
	UnmatchedHorseIDs     []string  `json:"unmatchedHorseIDs"`
	UnmatchedSelectionIDs []int64   `json:"unmatchedSelectionIDs"`
}

// Overlap is the share of our runners that found a selection.
func (r RunnerMatch) Overlap() float64 {
	total := len(r.Pairings) + len(r.UnmatchedHorseIDs)
	if total == 0 {
		return 0
	}
	return float64(len(r.Pairings)) / float64(total)
}

// MatchRunners joins our runners to an exchange's selections in three passes:
// saddle cloth, exact name, near-identical name. Each pass only sees what the
// previous left, and each accepts only one-to-one pairings.
//
// allowClothNumbers must be false while deciding WHICH market a race is: every
// race numbers its runners from one, so cloths agree between any two races of
// the same size and would manufacture agreement.
func MatchRunners(runners []domain.Runner, selections []ExchangeRunner, tol Tolerances, allowClothNumbers bool) RunnerMatch {
	remainingRunners := append([]domain.Runner(nil), runners...)
	remainingSelections := append([]ExchangeRunner(nil), selections...)
	var pairings []Pairing

	ourKeys := map[string][]domain.Runner{}
	for _, r := range runners {
		k := HorseKey(r.Name)
		ourKeys[k] = append(ourKeys[k], r)
	}

	// Pass 1 — saddle cloth.
	if allowClothNumbers {
		var proposed []Pairing
		for _, r := range remainingRunners {
			if r.ClothNumber == nil || *r.ClothNumber <= 0 {
				continue
			}
			var candidates []ExchangeRunner
			for _, s := range remainingSelections {
				if s.ClothNumber != nil && *s.ClothNumber == *r.ClothNumber {
					candidates = append(candidates, s)
				}
			}
			if len(candidates) != 1 {
				continue
			}
			sel := candidates[0]
			// The contradiction guard: if the selection's name is plainly one of
			// our other runners, the numbering disagrees and the cloth is wrong.
			if namesakes := ourKeys[HorseKey(sel.Name)]; len(namesakes) == 1 && namesakes[0].ID != r.ID {
				continue
			}
			proposed = append(proposed, Pairing{r.ID, r.Name, sel.ID, ByClothNumber})
		}
		consume(proposed, &remainingRunners, &remainingSelections, &pairings)
	}

	// Pass 2 — exact normalised name.
	{
		selectionKeys := map[string][]ExchangeRunner{}
		for _, s := range remainingSelections {
			k := HorseKey(s.Name)
			selectionKeys[k] = append(selectionKeys[k], s)
		}
		var proposed []Pairing
		for _, r := range remainingRunners {
			k := HorseKey(r.Name)
			if c := selectionKeys[k]; k != "" && len(c) == 1 {
				proposed = append(proposed, Pairing{r.ID, r.Name, c[0].ID, ByExactName})
			}
		}
		consume(proposed, &remainingRunners, &remainingSelections, &pairings)
	}

	// Pass 3 — near-identical name, only with a unique best candidate.
	if tol.MaximumNameDistance > 0 {
		var proposed []Pairing
		for _, r := range remainingRunners {
			k := HorseKey(r.Name)
			if k == "" {
				continue
			}
			var best *ExchangeRunner
			bestDistance, tied := 0, false
			for i := range remainingSelections {
				s := remainingSelections[i]
				d := NameDistance(k, HorseKey(s.Name), tol.MaximumNameDistance)
				if d < 0 {
					continue
				}
				switch {
				case best == nil || d < bestDistance:
					best, bestDistance, tied = &remainingSelections[i], d, false
				case d == bestDistance:
					tied = true
				}
			}
			if best != nil && !tied {
				proposed = append(proposed, Pairing{r.ID, r.Name, best.ID, BySimilarName})
			}
		}
		consume(proposed, &remainingRunners, &remainingSelections, &pairings)
	}

	result := RunnerMatch{Pairings: pairings, UnmatchedHorseIDs: []string{}, UnmatchedSelectionIDs: []int64{}}
	if result.Pairings == nil {
		result.Pairings = []Pairing{}
	}
	for _, r := range remainingRunners {
		result.UnmatchedHorseIDs = append(result.UnmatchedHorseIDs, r.ID)
	}
	for _, s := range remainingSelections {
		result.UnmatchedSelectionIDs = append(result.UnmatchedSelectionIDs, s.ID)
	}
	return result
}

// consume accepts only pairings that are one-to-one within the pass: two
// runners proposed for one selection are both unsafe.
func consume(proposed []Pairing, runners *[]domain.Runner, selections *[]ExchangeRunner, accepted *[]Pairing) {
	count := map[int64]int{}
	for _, p := range proposed {
		count[p.SelectionID]++
	}
	takenHorses, takenSelections := map[string]bool{}, map[int64]bool{}
	for _, p := range proposed {
		if count[p.SelectionID] == 1 {
			*accepted = append(*accepted, p)
			takenHorses[p.HorseID] = true
			takenSelections[p.SelectionID] = true
		}
	}
	if len(takenHorses) == 0 {
		return
	}
	var rs []domain.Runner
	for _, r := range *runners {
		if !takenHorses[r.ID] {
			rs = append(rs, r)
		}
	}
	var ss []ExchangeRunner
	for _, s := range *selections {
		if !takenSelections[s.ID] {
			ss = append(ss, s)
		}
	}
	*runners, *selections = rs, ss
}

// Match is one race joined to one market.
type Match struct {
	RaceID       string      `json:"raceID"`
	MarketID     string      `json:"marketID"`
	MinutesApart float64     `json:"minutesApart"`
	NameEvidence float64     `json:"nameEvidence"`
	Runners      RunnerMatch `json:"runners"`
}

// Reference freezes the settlement coordinates, from the same pairings.
func (m Match) Reference() domain.MarketReference {
	ids := map[string]int64{}
	for _, p := range m.Runners.Pairings {
		ids[p.HorseID] = p.SelectionID
	}
	return domain.MarketReference{MarketID: m.MarketID, SelectionIDsByHorseID: ids}
}

// HorseIDsBySelectionID is the crossing map for the price join.
func (m Match) HorseIDsBySelectionID() map[int64]string {
	out := map[int64]string{}
	for _, p := range m.Runners.Pairings {
		out[p.SelectionID] = p.HorseID
	}
	return out
}

// Refusal says why a race has no market. None of these is an error.
type Refusal struct {
	Kind      string   `json:"kind"` // noOffTime, noCandidate, ambiguous, noOverlap, noRunners
	MarketIDs []string `json:"marketIDs,omitempty"`
	MarketID  string   `json:"marketID,omitempty"`
	Overlap   float64  `json:"overlap,omitempty"`
}

const (
	RefusedNoOffTime   = "noOffTime"
	RefusedNoCandidate = "noCandidate"
	RefusedAmbiguous   = "ambiguous"
	RefusedNoOverlap   = "noOverlap"
	RefusedNoRunners   = "noRunners"
)

// DisplayName is the one-line reason for the app.
func (r Refusal) DisplayName() string {
	switch r.Kind {
	case RefusedNoOffTime:
		return "No off time"
	case RefusedNoCandidate:
		return "No market found"
	case RefusedAmbiguous:
		return "More than one market fits"
	case RefusedNoOverlap:
		return "Runners don't match"
	case RefusedNoRunners:
		return "No declared runners"
	}
	return r.Kind
}

// Report is one matching pass.
type Report struct {
	Matches            []Match            `json:"matches"`
	Refusals           map[string]Refusal `json:"refusals"`
	UnclaimedMarketIDs []string           `json:"unclaimedMarketIDs"`
}

// MatchRaces joins races to markets. Course, off time and — the check that
// makes the first two safe — the horses themselves must agree.
func MatchRaces(races []domain.Race, markets []ExchangeMarket, tol Tolerances) Report {
	byCourse := map[string][]ExchangeMarket{}
	for _, m := range markets {
		k := CourseKey(m.Venue)
		byCourse[k] = append(byCourse[k], m)
	}
	report := Report{Matches: []Match{}, Refusals: map[string]Refusal{}, UnclaimedMarketIDs: []string{}}
	claimed := map[string]bool{}

	// Longest fields first, so the race we can be most confident about takes
	// its market with it.
	ordered := append([]domain.Race(nil), races...)
	sort.SliceStable(ordered, func(i, j int) bool { return len(ordered[i].Runners) > len(ordered[j].Runners) })

	window := tol.StartTimeWindowMinutes * 60
	for _, race := range ordered {
		runners := race.DeclaredRunners()
		if len(runners) == 0 {
			report.Refusals[race.ID] = Refusal{Kind: RefusedNoRunners}
			continue
		}
		off, ok := race.Off()
		if !ok {
			report.Refusals[race.ID] = Refusal{Kind: RefusedNoOffTime}
			continue
		}
		type scored struct {
			market ExchangeMarket
			result RunnerMatch
			apart  float64
		}
		var all []scored
		for _, m := range byCourse[CourseKey(race.CourseName)] {
			gap := math.Abs(m.StartTime.Sub(off).Seconds())
			if claimed[m.ID] || gap > window {
				continue
			}
			all = append(all, scored{m, MatchRunners(runners, m.ActiveRunners(), tol, false), gap / 60})
		}
		if len(all) == 0 {
			report.Refusals[race.ID] = Refusal{Kind: RefusedNoCandidate}
			continue
		}
		var viable []scored
		for _, s := range all {
			if s.result.Overlap() >= tol.MinimumRunnerOverlap {
				viable = append(viable, s)
			}
		}
		if len(viable) == 0 {
			best := all[0]
			for _, s := range all[1:] {
				if s.result.Overlap() > best.result.Overlap() {
					best = s
				}
			}
			report.Refusals[race.ID] = Refusal{Kind: RefusedNoOverlap, MarketID: best.market.ID, Overlap: best.result.Overlap()}
			continue
		}
		sort.SliceStable(viable, func(i, j int) bool {
			if viable[i].result.Overlap() != viable[j].result.Overlap() {
				return viable[i].result.Overlap() > viable[j].result.Overlap()
			}
			return viable[i].apart < viable[j].apart
		})
		winner := viable[0]
		if len(viable) > 1 {
			second := viable[1]
			if second.result.Overlap() == winner.result.Overlap() && second.apart == winner.apart {
				ids := []string{winner.market.ID, second.market.ID}
				sort.Strings(ids)
				report.Refusals[race.ID] = Refusal{Kind: RefusedAmbiguous, MarketIDs: ids}
				continue
			}
		}
		// Now the market is settled, cloth numbers may fill in the runners
		// whose names the two feeds spell differently.
		final := MatchRunners(runners, winner.market.ActiveRunners(), tol, true)
		claimed[winner.market.ID] = true
		report.Matches = append(report.Matches, Match{
			RaceID: race.ID, MarketID: winner.market.ID, MinutesApart: winner.apart,
			NameEvidence: winner.result.Overlap(), Runners: final,
		})
	}
	for _, m := range markets {
		if !claimed[m.ID] {
			report.UnclaimedMarketIDs = append(report.UnclaimedMarketIDs, m.ID)
		}
	}
	return report
}

// ExchangePrices is one market's prices keyed by the exchange's selection id.
type ExchangePrices struct {
	MarketID   string
	Status     string
	CapturedAt time.Time
	IsDelayed  bool
	Prices     map[int64]domain.RunnerPrice
}

// Snapshot is the one crossing from the exchange's ids to ours. It DROPS
// prices for unmatched selections: a price on the wrong horse looks normal and
// silently anchors the model to another animal.
func Snapshot(prices ExchangePrices, horseIDsBySelectionID map[int64]string, source domain.MarketSource) domain.MarketSnapshot {
	byHorse := map[string]domain.RunnerPrice{}
	for sel, p := range prices.Prices {
		if horse, ok := horseIDsBySelectionID[sel]; ok {
			byHorse[horse] = p
		}
	}
	id := prices.MarketID
	return domain.MarketSnapshot{MarketID: &id, Source: source, CapturedAt: domain.At(prices.CapturedAt), IsDelayed: prices.IsDelayed, Prices: byHorse}
}
