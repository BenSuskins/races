package tracking

import (
	"math"
	"sort"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
)

// Archive is jockey and trainer strike rates from results the server has seen.
// Ingestion is idempotent: the results endpoint is polled all afternoon, and
// counting a race twice would inflate every figure derived from it.
//
// The JSON is ResultsArchive's, so a device's archive seeds this one.
type Archive struct {
	Jockeys          map[string]rating.StrikeRate   `json:"jockeys"`
	Trainers         map[string]rating.StrikeRate   `json:"trainers"`
	JockeySurfaces   map[string]rating.StrikeRate   `json:"jockeySurfaces,omitempty"`
	TrainerSurfaces  map[string]rating.StrikeRate   `json:"trainerSurfaces,omitempty"`
	JockeyRaceTypes  map[string]rating.StrikeRate   `json:"jockeyRaceTypes,omitempty"`
	TrainerRaceTypes map[string]rating.StrikeRate   `json:"trainerRaceTypes,omitempty"`
	JockeyGoings     map[string]rating.StrikeRate   `json:"jockeyGoings,omitempty"`
	TrainerGoings    map[string]rating.StrikeRate   `json:"trainerGoings,omitempty"`
	HorseGoing       map[string]rating.PlaceRate    `json:"horseGoing,omitempty"`
	HorseOverall     map[string]rating.PlaceRate    `json:"horseOverall,omitempty"`
	JockeyRecent     map[string][]RecentRun         `json:"jockeyRecent,omitempty"`
	TrainerRecent    map[string][]RecentRun         `json:"trainerRecent,omitempty"`
	JockeyTrainer    map[string]rating.StrikeRate   `json:"jockeyTrainerPairs,omitempty"`
	DrawBias         map[string]rating.DrawBiasRate `json:"drawBias,omitempty"`
	HorseClass       map[string][]ClassRun          `json:"horseClass,omitempty"`
	IngestedRaceIDs  []string                       `json:"ingestedRaceIDs"`
	TotalRuns        int                            `json:"totalRuns"`
	TotalWins        int                            `json:"totalWins"`

	ingested map[string]bool
}

// RecentRun is one dated ride retained for the recent-form window.
type RecentRun struct {
	Date    string `json:"date"`
	RaceID  string `json:"raceID"`
	HorseID string `json:"horseID"`
	Won     bool   `json:"won"`
}

type ClassRun struct {
	Date      string  `json:"date"`
	RaceID    string  `json:"raceID"`
	RaceClass int     `json:"raceClass"`
	Score     float64 `json:"score"`
}

const RecentRunWindow = 50

func NewArchive() *Archive {
	return &Archive{Jockeys: map[string]rating.StrikeRate{}, Trainers: map[string]rating.StrikeRate{}, JockeySurfaces: map[string]rating.StrikeRate{}, TrainerSurfaces: map[string]rating.StrikeRate{}, JockeyRaceTypes: map[string]rating.StrikeRate{}, TrainerRaceTypes: map[string]rating.StrikeRate{}, JockeyGoings: map[string]rating.StrikeRate{}, TrainerGoings: map[string]rating.StrikeRate{}, HorseGoing: map[string]rating.PlaceRate{}, HorseOverall: map[string]rating.PlaceRate{}, JockeyRecent: map[string][]RecentRun{}, TrainerRecent: map[string][]RecentRun{}, JockeyTrainer: map[string]rating.StrikeRate{}, DrawBias: map[string]rating.DrawBiasRate{}, HorseClass: map[string][]ClassRun{}, ingested: map[string]bool{}}
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
	if a.JockeySurfaces == nil {
		a.JockeySurfaces = map[string]rating.StrikeRate{}
	}
	if a.TrainerSurfaces == nil {
		a.TrainerSurfaces = map[string]rating.StrikeRate{}
	}
	if a.JockeyRaceTypes == nil {
		a.JockeyRaceTypes = map[string]rating.StrikeRate{}
	}
	if a.TrainerRaceTypes == nil {
		a.TrainerRaceTypes = map[string]rating.StrikeRate{}
	}
	if a.JockeyGoings == nil {
		a.JockeyGoings = map[string]rating.StrikeRate{}
	}
	if a.TrainerGoings == nil {
		a.TrainerGoings = map[string]rating.StrikeRate{}
	}
	if a.HorseGoing == nil {
		a.HorseGoing = map[string]rating.PlaceRate{}
	}
	if a.HorseOverall == nil {
		a.HorseOverall = map[string]rating.PlaceRate{}
	}
	if a.JockeyRecent == nil {
		a.JockeyRecent = map[string][]RecentRun{}
	}
	if a.TrainerRecent == nil {
		a.TrainerRecent = map[string][]RecentRun{}
	}
	if a.JockeyTrainer == nil {
		a.JockeyTrainer = map[string]rating.StrikeRate{}
	}
	if a.DrawBias == nil {
		a.DrawBias = map[string]rating.DrawBiasRate{}
	}
	if a.HorseClass == nil {
		a.HorseClass = map[string][]ClassRun{}
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
	validRecentDate := false
	if _, err := time.Parse("2006-01-02", r.Date); err == nil {
		validRecentDate = true
	}
	for _, f := range r.Finishers {
		if validRecentDate && r.RaceClass != nil && *r.RaceClass >= 1 && *r.RaceClass <= 7 && len(r.Finishers) >= 2 {
			score := 0.0
			if position := f.Position.NumericPosition(); position != nil && *position >= 1 && *position <= len(r.Finishers) {
				score = 1 - float64(*position-1)/float64(len(r.Finishers)-1)
			}
			a.HorseClass[f.HorseID] = appendClassRun(a.HorseClass[f.HorseID], ClassRun{Date: r.Date, RaceID: r.ID, RaceClass: *r.RaceClass, Score: score})
		}
		won := f.Position.IsWinner()
		a.TotalRuns++
		if won {
			a.TotalWins++
		}
		if f.JockeyID != nil {
			a.Jockeys[*f.JockeyID] = bump(a.Jockeys[*f.JockeyID], won)
			if r.Surface != domain.SurfaceUnknown {
				key := surfaceSubjectKey(*f.JockeyID, r.Surface)
				a.JockeySurfaces[key] = bump(a.JockeySurfaces[key], won)
			}
			if r.Type != domain.RaceTypeUnknown {
				key := raceTypeSubjectKey(*f.JockeyID, r.Type)
				a.JockeyRaceTypes[key] = bump(a.JockeyRaceTypes[key], won)
			}
			if bucket := r.Going.Bucket(r.Surface); bucket != "" {
				key := goingSubjectKey(*f.JockeyID, r.Surface, bucket)
				a.JockeyGoings[key] = bump(a.JockeyGoings[key], won)
			}
			if validRecentDate {
				a.JockeyRecent[*f.JockeyID] = appendRecent(a.JockeyRecent[*f.JockeyID], RecentRun{Date: r.Date, RaceID: r.ID, HorseID: f.HorseID, Won: won})
			}
		}
		if f.TrainerID != nil {
			a.Trainers[*f.TrainerID] = bump(a.Trainers[*f.TrainerID], won)
			if r.Surface != domain.SurfaceUnknown {
				key := surfaceSubjectKey(*f.TrainerID, r.Surface)
				a.TrainerSurfaces[key] = bump(a.TrainerSurfaces[key], won)
			}
			if r.Type != domain.RaceTypeUnknown {
				key := raceTypeSubjectKey(*f.TrainerID, r.Type)
				a.TrainerRaceTypes[key] = bump(a.TrainerRaceTypes[key], won)
			}
			if bucket := r.Going.Bucket(r.Surface); bucket != "" {
				key := goingSubjectKey(*f.TrainerID, r.Surface, bucket)
				a.TrainerGoings[key] = bump(a.TrainerGoings[key], won)
			}
			if validRecentDate {
				a.TrainerRecent[*f.TrainerID] = appendRecent(a.TrainerRecent[*f.TrainerID], RecentRun{Date: r.Date, RaceID: r.ID, HorseID: f.HorseID, Won: won})
			}
		}
		if f.JockeyID != nil && f.TrainerID != nil {
			key := jockeyTrainerKey(*f.JockeyID, *f.TrainerID)
			a.JockeyTrainer[key] = bump(a.JockeyTrainer[key], won)
		}
		if f.Draw != nil {
			if key, ok := domain.DrawBiasCellKey(r.CourseName, r.Distance, r.Surface, r.Going, len(r.Finishers), *f.Draw); ok {
				record := a.DrawBias[key]
				record.Runs++
				record.ExpectedWins += 1 / float64(len(r.Finishers))
				if won {
					record.Wins++
				}
				a.DrawBias[key] = record
			}
		}
		if f.Position.Kind == domain.PositionFinished {
			placed := f.Position.Position <= 3
			record := a.HorseOverall[f.HorseID]
			record.Runs++
			if placed {
				record.Places++
			}
			a.HorseOverall[f.HorseID] = record
			if bucket := r.Going.Bucket(r.Surface); bucket != "" {
				key := horseGoingKey(f.HorseID, r.Surface, bucket)
				record := a.HorseGoing[key]
				record.Runs++
				if placed {
					record.Places++
				}
				a.HorseGoing[key] = record
			}
		}
	}
	return true
}

func appendRecent(runs []RecentRun, run RecentRun) []RecentRun {
	runs = append(runs, run)
	sort.Slice(runs, func(i, j int) bool {
		if runs[i].Date != runs[j].Date {
			return runs[i].Date < runs[j].Date
		}
		if runs[i].RaceID != runs[j].RaceID {
			return runs[i].RaceID < runs[j].RaceID
		}
		return runs[i].HorseID < runs[j].HorseID
	})
	if len(runs) > RecentRunWindow {
		runs = append([]RecentRun(nil), runs[len(runs)-RecentRunWindow:]...)
	}
	return runs
}

func recentStrikeRate(runs []RecentRun) (rating.StrikeRate, bool) {
	if len(runs) == 0 {
		return rating.StrikeRate{}, false
	}
	rate := rating.StrikeRate{Runs: len(runs)}
	for _, run := range runs {
		if run.Won {
			rate.Wins++
		}
	}
	return rate, true
}

func jockeyTrainerKey(jockeyID, trainerID string) string { return jockeyID + "|" + trainerID }

func surfaceSubjectKey(id string, surface domain.Surface) string {
	return id + "|" + string(surface)
}

func raceTypeSubjectKey(id string, raceType domain.RaceType) string {
	return id + "|" + string(raceType)
}

func horseGoingKey(horseID string, surface domain.Surface, bucket domain.GoingBucket) string {
	return horseID + "|" + string(surface) + "|" + string(bucket)
}

func goingSubjectKey(id string, surface domain.Surface, bucket domain.GoingBucket) string {
	return id + "|" + string(surface) + "|" + string(bucket)
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
	for id, s := range other.JockeySurfaces {
		current := a.JockeySurfaces[id]
		a.JockeySurfaces[id] = rating.StrikeRate{Runs: current.Runs + s.Runs, Wins: current.Wins + s.Wins}
	}
	for id, s := range other.TrainerSurfaces {
		current := a.TrainerSurfaces[id]
		a.TrainerSurfaces[id] = rating.StrikeRate{Runs: current.Runs + s.Runs, Wins: current.Wins + s.Wins}
	}
	for id, s := range other.JockeyRaceTypes {
		current := a.JockeyRaceTypes[id]
		a.JockeyRaceTypes[id] = rating.StrikeRate{Runs: current.Runs + s.Runs, Wins: current.Wins + s.Wins}
	}
	for id, s := range other.TrainerRaceTypes {
		current := a.TrainerRaceTypes[id]
		a.TrainerRaceTypes[id] = rating.StrikeRate{Runs: current.Runs + s.Runs, Wins: current.Wins + s.Wins}
	}
	for id, s := range other.JockeyGoings {
		current := a.JockeyGoings[id]
		a.JockeyGoings[id] = rating.StrikeRate{Runs: current.Runs + s.Runs, Wins: current.Wins + s.Wins}
	}
	for id, s := range other.TrainerGoings {
		current := a.TrainerGoings[id]
		a.TrainerGoings[id] = rating.StrikeRate{Runs: current.Runs + s.Runs, Wins: current.Wins + s.Wins}
	}
	for id, s := range other.HorseGoing {
		current := a.HorseGoing[id]
		a.HorseGoing[id] = rating.PlaceRate{Runs: current.Runs + s.Runs, Places: current.Places + s.Places}
	}
	for id, s := range other.HorseOverall {
		current := a.HorseOverall[id]
		a.HorseOverall[id] = rating.PlaceRate{Runs: current.Runs + s.Runs, Places: current.Places + s.Places}
	}
	for id, runs := range other.JockeyRecent {
		for _, run := range runs {
			a.JockeyRecent[id] = appendRecent(a.JockeyRecent[id], run)
		}
	}
	for id, runs := range other.TrainerRecent {
		for _, run := range runs {
			a.TrainerRecent[id] = appendRecent(a.TrainerRecent[id], run)
		}
	}
	for id, record := range other.JockeyTrainer {
		current := a.JockeyTrainer[id]
		a.JockeyTrainer[id] = rating.StrikeRate{Runs: current.Runs + record.Runs, Wins: current.Wins + record.Wins}
	}
	for key, record := range other.DrawBias {
		current := a.DrawBias[key]
		a.DrawBias[key] = rating.DrawBiasRate{Runs: current.Runs + record.Runs, Wins: current.Wins + record.Wins, ExpectedWins: current.ExpectedWins + record.ExpectedWins}
	}
	for key, record := range other.HorseClass {
		for _, run := range record {
			a.HorseClass[key] = appendClassRun(a.HorseClass[key], run)
		}
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

func (a *Archive) JockeySurfaceStrikeRate(id string, surface domain.Surface) (rating.StrikeRate, bool) {
	a.index()
	record, ok := a.JockeySurfaces[surfaceSubjectKey(id, surface)]
	return record, ok
}

func (a *Archive) TrainerSurfaceStrikeRate(id string, surface domain.Surface) (rating.StrikeRate, bool) {
	a.index()
	record, ok := a.TrainerSurfaces[surfaceSubjectKey(id, surface)]
	return record, ok
}

func (a *Archive) JockeyRaceTypeStrikeRate(id string, raceType domain.RaceType) (rating.StrikeRate, bool) {
	a.index()
	record, ok := a.JockeyRaceTypes[raceTypeSubjectKey(id, raceType)]
	return record, ok
}

func (a *Archive) TrainerRaceTypeStrikeRate(id string, raceType domain.RaceType) (rating.StrikeRate, bool) {
	a.index()
	record, ok := a.TrainerRaceTypes[raceTypeSubjectKey(id, raceType)]
	return record, ok
}

func (a *Archive) JockeyGoingStrikeRate(id string, surface domain.Surface, bucket domain.GoingBucket) (rating.StrikeRate, bool) {
	a.index()
	record, ok := a.JockeyGoings[goingSubjectKey(id, surface, bucket)]
	return record, ok
}

func (a *Archive) TrainerGoingStrikeRate(id string, surface domain.Surface, bucket domain.GoingBucket) (rating.StrikeRate, bool) {
	a.index()
	record, ok := a.TrainerGoings[goingSubjectKey(id, surface, bucket)]
	return record, ok
}

func (a *Archive) JockeyRecentStrikeRate(id string) (rating.StrikeRate, bool) {
	a.index()
	return recentStrikeRate(a.JockeyRecent[id])
}

func (a *Archive) TrainerRecentStrikeRate(id string) (rating.StrikeRate, bool) {
	a.index()
	return recentStrikeRate(a.TrainerRecent[id])
}

func (a *Archive) JockeyTrainerStrikeRate(jockeyID, trainerID string) (rating.StrikeRate, bool) {
	a.index()
	record, ok := a.JockeyTrainer[jockeyTrainerKey(jockeyID, trainerID)]
	return record, ok
}

func (a *Archive) DrawBiasRate(race domain.Race, runner domain.Runner) (rating.DrawBiasRate, bool) {
	a.index()
	if runner.Draw == nil {
		return rating.DrawBiasRate{}, false
	}
	fieldSize := len(race.Runners)
	if race.FieldSize != nil && *race.FieldSize > 0 {
		fieldSize = *race.FieldSize
	}
	key, ok := domain.DrawBiasCellKey(race.CourseName, race.Distance, race.Surface, race.Going, fieldSize, *runner.Draw)
	if !ok {
		return rating.DrawBiasRate{}, false
	}
	record, ok := a.DrawBias[key]
	return record, ok
}

func (a *Archive) HorseClassFormRate(horseID string, targetClass int) (rating.ClassAdjustedFormRate, bool) {
	a.index()
	if targetClass < 1 || targetClass > 7 {
		return rating.ClassAdjustedFormRate{}, false
	}
	runs := a.HorseClass[horseID]
	if len(runs) == 0 {
		return rating.ClassAdjustedFormRate{}, false
	}
	scoreTotal := 0.0
	for _, run := range runs {
		adjustment := float64(targetClass-run.RaceClass) * 0.04
		scoreTotal += math.Max(0, math.Min(1, run.Score+adjustment))
	}
	return rating.ClassAdjustedFormRate{Runs: len(runs), Score: scoreTotal / float64(len(runs))}, true
}

func appendClassRun(runs []ClassRun, run ClassRun) []ClassRun {
	runs = append(runs, run)
	sort.Slice(runs, func(i, j int) bool {
		if runs[i].Date != runs[j].Date {
			return runs[i].Date < runs[j].Date
		}
		return runs[i].RaceID < runs[j].RaceID
	})
	if len(runs) > RecentRunWindow {
		runs = append([]ClassRun(nil), runs[len(runs)-RecentRunWindow:]...)
	}
	return runs
}

func (a *Archive) HorseGoingRate(horseID string, surface domain.Surface, bucket domain.GoingBucket) (rating.PlaceRate, bool) {
	a.index()
	record, ok := a.HorseGoing[horseGoingKey(horseID, surface, bucket)]
	return record, ok
}

func (a *Archive) HorseOverallPlaceRate(horseID string) (rating.PlaceRate, bool) {
	a.index()
	record, ok := a.HorseOverall[horseID]
	return record, ok
}

// BaselineStrikeRate falls back to 1/8 until there are 100 runs to measure.
func (a *Archive) BaselineStrikeRate() float64 {
	if a.TotalRuns < 100 {
		return 0.125
	}
	return float64(a.TotalWins) / float64(a.TotalRuns)
}
