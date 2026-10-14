package rating_test

import (
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
)

func contribution(t *testing.T, assessment rating.Assessment, horse string, factor rating.FactorID) rating.Contribution {
	t.Helper()
	for _, runner := range assessment.Runners {
		if runner.HorseID != horse {
			continue
		}
		for _, reading := range runner.Contributions {
			if reading.Factor == factor {
				return reading
			}
		}
	}
	t.Fatalf("missing contribution %s for %s", factor, horse)
	return rating.Contribution{}
}

func number(value float64) *float64 { return &value }
func text(value string) *string     { return &value }

var ratingTime = time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)

func TestExchangeDepthUsesTwoSidedOffersBeforeRatingTime(t *testing.T) {
	race := domain.Race{ID: "race", Runners: []domain.Runner{{ID: "a"}, {ID: "b"}}}
	market := domain.MarketSnapshot{Source: domain.SourceLiveExchange, CapturedAt: domain.At(ratingTime), Prices: map[string]domain.RunnerPrice{
		"a": {BackPrice: number(2), LayPrice: number(2.02), BackSize: number(100), LaySize: number(80), IsActive: true},
		"b": {BackPrice: number(2), LayPrice: number(2.02), BackSize: number(10), LaySize: number(8), IsActive: true},
	}}
	assessment := rating.NewRater(rating.V3()).Rate(race, &market, nil, ratingTime)
	reading := contribution(t, assessment, "a", rating.FactorID("exchangeDepth"))
	if !reading.Availability.IsAvailable() || reading.ZScore == nil || *reading.ZScore <= 0 {
		t.Fatalf("deeper two-sided offers must yield a larger score: %+v", reading)
	}
	market.CapturedAt = domain.At(ratingTime.Add(time.Minute))
	reading = contribution(t, rating.NewRater(rating.V3()).Rate(race, &market, nil, ratingTime), "a", rating.FactorID("exchangeDepth"))
	if reading.Availability.IsAvailable() || reading.ZScore != nil {
		t.Fatal("future prices must not enter the factor")
	}
}

func TestHorseSuitabilityUsesConfirmedComparablePriorRuns(t *testing.T) {
	archive := tracking.NewArchive()
	for index := 0; index < 3; index++ {
		prior := domain.RaceResult{ID: string(rune('a' + index)), Date: "2026-10-01", CourseName: "Ascot", Surface: domain.SurfaceTurf, Type: domain.RaceTypeFlat, Distance: &domain.Distance{Furlongs: 8}, Finishers: []domain.Finisher{{HorseID: "a", Position: domain.Finished(1)}, {HorseID: "b", Position: domain.Finished(5)}}}
		archive.Ingest(prior)
	}
	race := domain.Race{ID: "race", CourseName: "Ascot", Surface: domain.SurfaceTurf, Type: domain.RaceTypeFlat, Distance: &domain.Distance{Furlongs: 8}, Runners: []domain.Runner{{ID: "a"}, {ID: "b"}}}
	assessment := rating.NewRater(rating.V3()).Rate(race, nil, archive, ratingTime)
	for _, factor := range []rating.FactorID{"horseCoursePlaceRate", "horseDistancePlaceRate", "horseSurfacePlaceRate"} {
		reading := contribution(t, assessment, "a", factor)
		if !reading.Availability.IsAvailable() || reading.ZScore == nil || *reading.ZScore <= 0 {
			t.Fatalf("prior comparable places must provide a score for %s: %+v", factor, reading)
		}
	}
	future := tracking.NewArchive()
	for index := 0; index < 3; index++ {
		future.Ingest(domain.RaceResult{ID: string(rune('a' + index)), Date: "2026-10-15", CourseName: "Ascot", Surface: domain.SurfaceTurf, Type: domain.RaceTypeFlat, Distance: &domain.Distance{Furlongs: 8}, Finishers: []domain.Finisher{{HorseID: "a", Position: domain.Finished(1)}}})
	}
	reading := contribution(t, rating.NewRater(rating.V3()).Rate(race, nil, future, ratingTime), "a", "horseDistancePlaceRate")
	if reading.Availability.IsAvailable() {
		t.Fatal("future results must not establish suitability")
	}
}

func TestHeadgearChangeUsesTheLatestConfirmedPriorRun(t *testing.T) {
	archive := tracking.NewArchive()
	archive.Ingest(domain.RaceResult{ID: "prior", Date: "2026-10-01", Finishers: []domain.Finisher{{HorseID: "a", Position: domain.Finished(1), HeadgearKnown: true}, {HorseID: "b", Position: domain.Finished(2), HeadgearKnown: true, Headgear: text("b")}}})
	archive.Ingest(domain.RaceResult{ID: "future", Date: "2026-10-15", Finishers: []domain.Finisher{{HorseID: "a", Position: domain.Finished(1), HeadgearKnown: true, Headgear: text("b")}}})
	race := domain.Race{ID: "race", Runners: []domain.Runner{{ID: "a", HeadgearKnown: true, Headgear: text("b")}, {ID: "b", HeadgearKnown: true, Headgear: text("b")}}}
	reading := contribution(t, rating.NewRater(rating.V3()).Rate(race, nil, archive, ratingTime), "a", "headgearChange")
	if !reading.Availability.IsAvailable() || reading.ZScore == nil || *reading.ZScore <= 0 {
		t.Fatalf("an observed equipment change must enter the snapshot: %+v", reading)
	}
	race.Runners[0].HeadgearKnown = false
	race.Runners[0].Headgear = nil
	reading = contribution(t, rating.NewRater(rating.V3()).Rate(race, nil, archive, ratingTime), "a", "headgearChange")
	if reading.Availability.IsAvailable() {
		t.Fatal("unknown current equipment cannot establish a change")
	}
}

func TestPedigreeSuitabilityPoolsOnlyComparablePriorOffspring(t *testing.T) {
	archive := tracking.NewArchive()
	for index := 0; index < 30; index++ {
		archive.Ingest(domain.RaceResult{ID: string(rune('a' + index)), Date: "2026-10-01", Surface: domain.SurfaceTurf, Type: domain.RaceTypeFlat, Going: domain.GoingGood, Distance: &domain.Distance{Furlongs: 8}, Finishers: []domain.Finisher{
			{HorseID: "offspring-a" + string(rune('a'+index)), SireID: text("sire-a"), DamsireID: text("damsire-a"), Position: domain.Finished(1)},
			{HorseID: "offspring-b" + string(rune('a'+index)), SireID: text("sire-b"), DamsireID: text("damsire-b"), Position: domain.Finished(5)},
		}})
	}
	race := domain.Race{ID: "race", Surface: domain.SurfaceTurf, Type: domain.RaceTypeFlat, Going: domain.GoingGood, Distance: &domain.Distance{Furlongs: 8}, Runners: []domain.Runner{{ID: "a", SireID: text("sire-a"), DamsireID: text("damsire-a")}, {ID: "b", SireID: text("sire-b"), DamsireID: text("damsire-b")}}}
	assessment := rating.NewRater(rating.V3()).Rate(race, nil, archive, ratingTime)
	for _, factor := range []rating.FactorID{"sireSuitability", "damsireSuitability"} {
		reading := contribution(t, assessment, "a", factor)
		if !reading.Availability.IsAvailable() || reading.ZScore == nil || *reading.ZScore <= 0 {
			t.Fatalf("pooled offspring record is missing for %s: %+v", factor, reading)
		}
	}
	race.Going = domain.GoingSoft
	reading := contribution(t, rating.NewRater(rating.V3()).Rate(race, nil, archive, ratingTime), "a", "sireSuitability")
	if reading.Availability.IsAvailable() {
		t.Fatal("a good-ground record must not supply soft-ground suitability")
	}
}

func TestNewFactorsRecordInputsWithoutChangingDefaultPredictions(t *testing.T) {
	race := domain.Race{ID: "race", Runners: []domain.Runner{{ID: "a"}, {ID: "b"}}}
	market := domain.MarketSnapshot{Source: domain.SourceLiveExchange, CapturedAt: domain.At(ratingTime), Prices: map[string]domain.RunnerPrice{
		"a": {BackPrice: number(2), LayPrice: number(2.02), BackSize: number(100), LaySize: number(80), IsActive: true},
		"b": {BackPrice: number(3), LayPrice: number(3.1), BackSize: number(10), LaySize: number(8), IsActive: true},
	}}
	full := rating.NewRater(rating.V3())
	baseline := rating.NewRater(rating.V3())
	baseline.Factors = baseline.Factors[:24]
	actual := full.Rate(race, &market, nil, ratingTime)
	expected := baseline.Rate(race, &market, nil, ratingTime)
	if actual.TrainingSnapshot == nil || len(actual.TrainingSnapshot.FactorIDs) != 31 {
		t.Fatal("the seven new factors must enter immutable training inputs")
	}
	for index, runner := range actual.Runners {
		if runner.WinProbability != expected.Runners[index].WinProbability {
			t.Fatal("zero defaults must preserve current predictions")
		}
		for _, reading := range runner.Contributions {
			if reading.Factor == rating.ExchangeDepth && reading.Weight != 0 {
				t.Fatal("new factors need validation before activation")
			}
		}
	}
}

func TestThinHorseHistoryDoesNotInventSuitability(t *testing.T) {
	archive := tracking.NewArchive()
	for index := 0; index < 2; index++ {
		archive.Ingest(domain.RaceResult{ID: string(rune('a' + index)), Date: "2026-10-01", Surface: domain.SurfaceTurf, Type: domain.RaceTypeFlat, Distance: &domain.Distance{Furlongs: 8}, Finishers: []domain.Finisher{{HorseID: "horse", Position: domain.Finished(1)}}})
	}
	race := domain.Race{ID: "race", Surface: domain.SurfaceTurf, Type: domain.RaceTypeFlat, Distance: &domain.Distance{Furlongs: 8}, Runners: []domain.Runner{{ID: "horse"}, {ID: "new"}}}
	reading := contribution(t, rating.NewRater(rating.V3()).Rate(race, nil, archive, ratingTime), "horse", rating.HorseDistancePlaceRate)
	if reading.Availability.IsAvailable() || reading.ZScore != nil {
		t.Fatal("two prior runs cannot satisfy the three-run minimum")
	}
}

func TestAnUnknownFinisherDoesNotEstablishHeadgearHistory(t *testing.T) {
	archive := tracking.NewArchive()
	archive.Ingest(domain.RaceResult{ID: "unknown", Date: "2026-10-01", Finishers: []domain.Finisher{{HorseID: "a", HeadgearKnown: true, Headgear: text("b")}}})
	race := domain.Race{ID: "race", Runners: []domain.Runner{{ID: "a", HeadgearKnown: true, Headgear: text("v")}, {ID: "b"}}}
	reading := contribution(t, rating.NewRater(rating.V3()).Rate(race, nil, archive, ratingTime), "a", rating.HeadgearChange)
	if reading.Availability.IsAvailable() {
		t.Fatal("an unknown finish does not confirm a previous run")
	}
}
