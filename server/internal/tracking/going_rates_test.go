package tracking

import (
	"fmt"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
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
	if rate, ok := a.JockeyTrainerStrikeRate(jockey, trainer); !ok || rate.Runs != 3 || rate.Wins != 2 {
		t.Fatalf("jockey-trainer interaction rate = %+v, %v", rate, ok)
	}
}

func TestArchiveKeepsTheLatestFiftyDatedRunsInChronologicalOrder(t *testing.T) {
	a := NewArchive()
	jockey, trainer := "jockey", "trainer"
	for index := 51; index >= 1; index-- {
		date := time.Date(2026, time.January, index, 0, 0, 0, 0, time.UTC).Format("2006-01-02")
		won := index <= 30
		position := 2
		if won {
			position = 1
		}
		a.Ingest(domain.RaceResult{ID: fmt.Sprintf("race-%02d", index), Date: date, Finishers: []domain.Finisher{{HorseID: fmt.Sprintf("horse-%02d", index), Position: domain.Finished(position), JockeyID: &jockey, TrainerID: &trainer}}})
	}
	for _, lookup := range []struct {
		name string
		get  func(string) (rating.StrikeRate, bool)
	}{
		{"jockey", a.JockeyRecentStrikeRate}, {"trainer", a.TrainerRecentStrikeRate},
	} {
		rate, ok := lookup.get(lookup.name)
		if !ok || rate.Runs != RecentRunWindow || rate.Wins != 29 {
			t.Fatalf("%s recent rate = %+v, %v", lookup.name, rate, ok)
		}
	}
}

func TestArchiveTracksDrawBandOutcomesAcrossComparableRaces(t *testing.T) {
	archive := NewArchive()
	distance := &domain.Distance{Furlongs: 5}
	for raceIndex := 1; raceIndex <= 100; raceIndex++ {
		finishers := make([]domain.Finisher, 0, 12)
		winnerDraw := 12
		if raceIndex <= 60 {
			winnerDraw = 2
		}
		for draw := 1; draw <= 12; draw++ {
			position := 2
			if draw == winnerDraw {
				position = 1
			}
			finishers = append(finishers, domain.Finisher{HorseID: fmt.Sprintf("horse-%d-%d", raceIndex, draw), Draw: &draw, Position: domain.Finished(position)})
		}
		archive.Ingest(domain.RaceResult{ID: fmt.Sprintf("race-%03d", raceIndex), CourseName: "Ascot", Distance: distance, Surface: domain.SurfaceTurf, Going: domain.GoingGood, Finishers: finishers})
	}
	fieldSize, draw := 12, 2
	race := domain.Race{CourseName: "ASCOT", Distance: distance, Surface: domain.SurfaceTurf, Going: domain.GoingGood, FieldSize: &fieldSize, Runners: []domain.Runner{{ID: "horse", Draw: &draw}}}
	record, ok := archive.DrawBiasRate(race, race.Runners[0])
	if !ok || record.Runs != 400 || record.Wins != 60 || record.ExpectedWins < 33.3 || record.ExpectedWins > 33.4 {
		t.Fatalf("unexpected comparable draw record: %+v, %v", record, ok)
	}
}

func TestArchiveTracksClassAdjustedHorseForm(t *testing.T) {
	archive := NewArchive()
	for _, race := range []domain.RaceResult{
		{ID: "class-1", Date: "2026-09-20", RaceClass: intPointer(1), Finishers: []domain.Finisher{{HorseID: "horse", Position: domain.Finished(1)}, {HorseID: "a", Position: domain.Finished(2)}, {HorseID: "b", Position: domain.Finished(3)}, {HorseID: "c", Position: domain.Finished(4)}}},
		{ID: "class-3", Date: "2026-09-21", RaceClass: intPointer(3), Finishers: []domain.Finisher{{HorseID: "x", Position: domain.Finished(1)}, {HorseID: "horse", Position: domain.Finished(2)}, {HorseID: "b", Position: domain.Finished(3)}, {HorseID: "c", Position: domain.Finished(4)}}},
		{ID: "class-5", Date: "2026-09-22", RaceClass: intPointer(5), Finishers: []domain.Finisher{{HorseID: "x", Position: domain.Finished(1)}, {HorseID: "a", Position: domain.Finished(2)}, {HorseID: "b", Position: domain.Finished(3)}, {HorseID: "horse", Position: domain.Finished(4)}}},
	} {
		archive.Ingest(race)
	}
	rate, ok := archive.HorseClassFormRate("horse", 3)
	if !ok || rate.Runs != 3 || rate.Score < 0.555 || rate.Score > 0.556 {
		t.Fatalf("class-adjusted horse form = %+v, %v", rate, ok)
	}
	window := NewArchive()
	for index := 1; index <= RecentRunWindow+1; index++ {
		position := 2
		if index%2 == 0 {
			position = 1
		}
		date := time.Date(2025, time.January, index, 0, 0, 0, 0, time.UTC).Format("2006-01-02")
		window.Ingest(domain.RaceResult{ID: fmt.Sprintf("window-%02d", index), Date: date, RaceClass: intPointer(3), Finishers: []domain.Finisher{{HorseID: "horse", Position: domain.Finished(position)}, {HorseID: "other", Position: domain.Finished(3)}}})
	}
	windowRate, ok := window.HorseClassFormRate("horse", 3)
	if !ok || windowRate.Runs != RecentRunWindow {
		t.Fatalf("class form did not retain its latest dated runs: %+v, %v", windowRate, ok)
	}
}

func intPointer(value int) *int { return &value }
