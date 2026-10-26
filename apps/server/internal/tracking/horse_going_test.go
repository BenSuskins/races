package tracking

import (
	"testing"

	"github.com/bensuskins/races/server/internal/domain"
)

func TestArchiveTracksHorsePlacesByBroadGoingAndSurface(t *testing.T) {
	a := NewArchive()
	for _, race := range []domain.RaceResult{
		{ID: "soft-1", Going: domain.GoingHeavy, Surface: domain.SurfaceTurf, Finishers: []domain.Finisher{{HorseID: "horse", Position: domain.Finished(2)}}},
		{ID: "soft-2", Going: domain.GoingSoft, Surface: domain.SurfaceTurf, Finishers: []domain.Finisher{{HorseID: "horse", Position: domain.Finished(4)}}},
		{ID: "good-1", Going: domain.GoingGood, Surface: domain.SurfaceTurf, Finishers: []domain.Finisher{{HorseID: "horse", Position: domain.Finished(1)}}},
	} {
		a.Ingest(race)
	}

	soft, ok := a.HorseGoingRate("horse", domain.SurfaceTurf, domain.GoingBucketSoft)
	if !ok || soft.Runs != 2 || soft.Places != 1 {
		t.Fatalf("soft bucket = %#v, %v", soft, ok)
	}
	good, ok := a.HorseGoingRate("horse", domain.SurfaceTurf, domain.GoingBucketGood)
	if !ok || good.Runs != 1 || good.Places != 1 {
		t.Fatalf("good bucket = %#v, %v", good, ok)
	}
	all, ok := a.HorseOverallPlaceRate("horse")
	if !ok || all.Runs != 3 || all.Places != 2 {
		t.Fatalf("overall = %#v, %v", all, ok)
	}
	if _, ok := a.HorseGoingRate("horse", domain.SurfaceAllWeather, domain.GoingBucketSoft); ok {
		t.Fatal("turf history entered the all-weather archive")
	}
}
