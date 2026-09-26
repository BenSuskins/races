package tracking

import (
	"testing"

	"github.com/bensuskins/races/server/internal/domain"
)

func TestArchiveTracksJockeyAndTrainerByRaceType(t *testing.T) {
	a := NewArchive()
	jockey, trainer := "jockey", "trainer"
	a.Ingest(domain.RaceResult{
		ID: "flat-race", Type: domain.RaceTypeFlat,
		Finishers: []domain.Finisher{{HorseID: "winner", Position: domain.Finished(1), JockeyID: &jockey, TrainerID: &trainer}},
	})
	a.Ingest(domain.RaceResult{
		ID: "hurdle-race", Type: domain.RaceTypeHurdle,
		Finishers: []domain.Finisher{{HorseID: "loser", Position: domain.Finished(2), JockeyID: &jockey, TrainerID: &trainer}},
	})

	for _, lookup := range []struct {
		name string
		get  func(domain.RaceType) (int, int, bool)
	}{
		{"jockey", func(raceType domain.RaceType) (int, int, bool) {
			rate, ok := a.JockeyRaceTypeStrikeRate(jockey, raceType)
			return rate.Runs, rate.Wins, ok
		}},
		{"trainer", func(raceType domain.RaceType) (int, int, bool) {
			rate, ok := a.TrainerRaceTypeStrikeRate(trainer, raceType)
			return rate.Runs, rate.Wins, ok
		}},
	} {
		for _, raceType := range []domain.RaceType{domain.RaceTypeFlat, domain.RaceTypeHurdle} {
			runs, wins, ok := lookup.get(raceType)
			if !ok || runs != 1 || wins != boolInt(raceType == domain.RaceTypeFlat) {
				t.Fatalf("%s %s rate = %d/%d, %v", lookup.name, raceType, wins, runs, ok)
			}
		}
	}
}
