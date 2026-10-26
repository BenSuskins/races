package tracking

import (
	"testing"

	"github.com/bensuskins/races/server/internal/domain"
)

func TestArchiveTracksJockeyAndTrainerBySurface(t *testing.T) {
	a := NewArchive()
	jockey, trainer := "jockey", "trainer"
	a.Ingest(domain.RaceResult{
		ID: "turf-race", Surface: domain.SurfaceTurf,
		Finishers: []domain.Finisher{{HorseID: "winner", Position: domain.Finished(1), JockeyID: &jockey, TrainerID: &trainer}},
	})
	a.Ingest(domain.RaceResult{
		ID: "aw-race", Surface: domain.SurfaceAllWeather,
		Finishers: []domain.Finisher{{HorseID: "loser", Position: domain.Finished(2), JockeyID: &jockey, TrainerID: &trainer}},
	})

	for _, lookup := range []struct {
		name string
		get  func(domain.Surface) (int, int, bool)
	}{
		{"jockey", func(surface domain.Surface) (int, int, bool) {
			rate, ok := a.JockeySurfaceStrikeRate(jockey, surface)
			return rate.Runs, rate.Wins, ok
		}},
		{"trainer", func(surface domain.Surface) (int, int, bool) {
			rate, ok := a.TrainerSurfaceStrikeRate(trainer, surface)
			return rate.Runs, rate.Wins, ok
		}},
	} {
		for _, surface := range []domain.Surface{domain.SurfaceTurf, domain.SurfaceAllWeather} {
			runs, wins, ok := lookup.get(surface)
			if !ok || runs != 1 || wins != boolInt(surface == domain.SurfaceTurf) {
				t.Fatalf("%s %s rate = %d/%d, %v", lookup.name, surface, wins, runs, ok)
			}
		}
	}
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
