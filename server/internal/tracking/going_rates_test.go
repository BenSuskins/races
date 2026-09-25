package tracking

import (
	"testing"

	"github.com/bensuskins/races/server/internal/domain"
)

func TestArchiveTracksJockeyAndTrainerByGoingBucket(t *testing.T) {
	a := NewArchive()
	jockey, trainer := "jockey", "trainer"
	for _, race := range []domain.RaceResult{
		{ID: "turf-good", Surface: domain.SurfaceTurf, Going: domain.GoingGood, Finishers: []domain.Finisher{{HorseID: "winner", Position: domain.Finished(1), JockeyID: &jockey, TrainerID: &trainer}}},
		{ID: "turf-soft", Surface: domain.SurfaceTurf, Going: domain.GoingSoft, Finishers: []domain.Finisher{{HorseID: "loser", Position: domain.Finished(2), JockeyID: &jockey, TrainerID: &trainer}}},
		{ID: "aw-fast", Surface: domain.SurfaceAllWeather, Going: domain.GoingStandardToFast, Finishers: []domain.Finisher{{HorseID: "aw-winner", Position: domain.Finished(1), JockeyID: &jockey, TrainerID: &trainer}}},
	} {
		a.Ingest(race)
	}

	for _, lookup := range []struct {
		name string
		get  func(domain.Surface, domain.GoingBucket) (int, int, bool)
	}{
		{"jockey", func(surface domain.Surface, bucket domain.GoingBucket) (int, int, bool) {
			rate, ok := a.JockeyGoingStrikeRate(jockey, surface, bucket)
			return rate.Runs, rate.Wins, ok
		}},
		{"trainer", func(surface domain.Surface, bucket domain.GoingBucket) (int, int, bool) {
			rate, ok := a.TrainerGoingStrikeRate(trainer, surface, bucket)
			return rate.Runs, rate.Wins, ok
		}},
	} {
		for _, cell := range []struct {
			surface domain.Surface
			bucket  domain.GoingBucket
			wins    int
		}{
			{domain.SurfaceTurf, domain.GoingBucketGood, 1},
			{domain.SurfaceTurf, domain.GoingBucketSoft, 0},
			{domain.SurfaceAllWeather, domain.GoingBucketFast, 1},
		} {
			runs, wins, ok := lookup.get(cell.surface, cell.bucket)
			if !ok || runs != 1 || wins != cell.wins {
				t.Fatalf("%s %s/%s rate = %d/%d, %v", lookup.name, cell.surface, cell.bucket, runs, wins, ok)
			}
		}
	}
}
