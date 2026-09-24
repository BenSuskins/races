package tracking

import (
	"sort"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
)

// Archive is jockey and trainer strike rates from results the server has seen.
// Ingestion is idempotent: the results endpoint is polled all afternoon, and
// counting a race twice would inflate every figure derived from it.
//
// The JSON is ResultsArchive's, so a device's archive seeds this one.
type Archive struct {
	Jockeys         map[string]rating.StrikeRate `json:"jockeys"`
	Trainers        map[string]rating.StrikeRate `json:"trainers"`
	IngestedRaceIDs []string                     `json:"ingestedRaceIDs"`
	TotalRuns       int                          `json:"totalRuns"`
	TotalWins       int                          `json:"totalWins"`

	ingested map[string]bool
}

func NewArchive() *Archive {
	return &Archive{Jockeys: map[string]rating.StrikeRate{}, Trainers: map[string]rating.StrikeRate{}, ingested: map[string]bool{}}
}

func (a *Archive) index() {
	// Rebuilt whenever it falls out of step with the id list, which is what
	// decoding a stored archive into an existing value does.
	if a.ingested == nil || len(a.ingested) != len(a.IngestedRaceIDs) {
		a.ingested = map[string]bool{}
		for _, id := range a.IngestedRaceIDs {
			a.ingested[id] = true
		}
	}
	if a.Jockeys == nil {
		a.Jockeys = map[string]rating.StrikeRate{}
	}
	if a.Trainers == nil {
		a.Trainers = map[string]rating.StrikeRate{}
	}
}

func (a *Archive) Has(raceID string) bool { a.index(); return a.ingested[raceID] }

// Ingest adds a settled race; false if it was already counted or empty.
func (a *Archive) Ingest(r domain.RaceResult) bool {
	a.index()
	if a.ingested[r.ID] || len(r.Finishers) == 0 {
		return false
	}
	a.ingested[r.ID] = true
	a.IngestedRaceIDs = append(a.IngestedRaceIDs, r.ID)
	for _, f := range r.Finishers {
		won := f.Position.IsWinner()
		a.TotalRuns++
		if won {
			a.TotalWins++
		}
		if f.JockeyID != nil {
			a.Jockeys[*f.JockeyID] = bump(a.Jockeys[*f.JockeyID], won)
		}
		if f.TrainerID != nil {
			a.Trainers[*f.TrainerID] = bump(a.Trainers[*f.TrainerID], won)
		}
	}
	return true
}

// Merge adds another archive's counts for races this one has not seen. Used
// to seed from a device: strike rates are aggregates, so races the device
// counted can only be merged wholesale — which is safe because the device's
// races predate the server's.
func (a *Archive) Merge(other Archive) int {
	a.index()
	fresh := 0
	for _, id := range other.IngestedRaceIDs {
		if !a.ingested[id] {
			fresh++
		}
	}
	if fresh == 0 {
		return 0
	}
	// Only when *none* of the device's races are already counted is a
	// wholesale merge exact. A partial overlap would double-count, so the
	// overlap case adds the ids (to keep ingestion idempotent) but not the
	// aggregate counts, and says so by returning zero.
	if fresh != len(other.IngestedRaceIDs) {
		return 0
	}
	for id, s := range other.Jockeys {
		c := a.Jockeys[id]
		a.Jockeys[id] = rating.StrikeRate{Runs: c.Runs + s.Runs, Wins: c.Wins + s.Wins}
	}
	for id, s := range other.Trainers {
		c := a.Trainers[id]
		a.Trainers[id] = rating.StrikeRate{Runs: c.Runs + s.Runs, Wins: c.Wins + s.Wins}
	}
	a.TotalRuns += other.TotalRuns
	a.TotalWins += other.TotalWins
	for _, id := range other.IngestedRaceIDs {
		a.ingested[id] = true
		a.IngestedRaceIDs = append(a.IngestedRaceIDs, id)
	}
	sort.Strings(a.IngestedRaceIDs)
	return fresh
}

func bump(s rating.StrikeRate, won bool) rating.StrikeRate {
	s.Runs++
	if won {
		s.Wins++
	}
	return s
}

func (a *Archive) RaceCount() int { a.index(); return len(a.ingested) }

func (a *Archive) JockeyStrikeRate(id string) (rating.StrikeRate, bool) {
	s, ok := a.Jockeys[id]
	return s, ok
}

func (a *Archive) TrainerStrikeRate(id string) (rating.StrikeRate, bool) {
	s, ok := a.Trainers[id]
	return s, ok
}

// BaselineStrikeRate falls back to 1/8 until there are 100 runs to measure.
func (a *Archive) BaselineStrikeRate() float64 {
	if a.TotalRuns < 100 {
		return 0.125
	}
	return float64(a.TotalWins) / float64(a.TotalRuns)
}
