package training

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
)

// samples where the official rating always identifies the winner and form says
// nothing — the same construction as RacesKit's trainer tests.
func samples(n int) []Race {
	out := make([]Race, n)
	for i := range out {
		winner := []string{"a", "b", "c"}[i%3]
		or := [][]float64{{2, -1, -1}, {-1, 2, -1}, {-1, -1, 2}}[i%3]
		out[i] = Race{
			Snapshot: rating.TrainingSnapshot{
				RaceID: fmt.Sprintf("race-%d", i), CreatedAt: domain.At(time.Unix(int64(i), 0)),
				RunnerIDs: []string{"a", "b", "c"}, MarketProbabilities: []float64{1.0 / 3, 1.0 / 3, 1.0 / 3},
				FactorIDs: []rating.FactorID{rating.OfficialRating, rating.RecentForm},
				ZScores:   [][]float64{or, {0, 0, 0}},
			},
			WinnerID: winner,
		}
	}
	return out
}

func TestDoesNotTrainBeforeMinimum(t *testing.T) {
	cfg := DefaultConfiguration()
	cfg.MinimumRaces = 20
	r := Train(samples(19), rating.V1(), cfg)
	if r.Trained || r.Promoted || r.SettledRaceCount != 19 || r.Weights.ID != "v1" {
		t.Fatalf("%+v", r)
	}
}

func TestHonoursTheHundredRaceFloor(t *testing.T) {
	cfg := DefaultConfiguration()
	cfg.MinimumRaces, cfg.ValidationRaces = 20, 5
	if r := Train(samples(40), rating.V1(), cfg); r.Trained {
		t.Fatal("35 training races is below the floor")
	}
}

func TestLearnsAFactorThatExplainsTheWinner(t *testing.T) {
	cfg := DefaultConfiguration()
	cfg.MinimumRaces, cfg.ValidationRaces, cfg.Epochs = 100, 30, 80
	r := Train(samples(150), rating.V1(), cfg)
	if !r.Trained || !r.Promoted || *r.CandidateValidationLogLoss >= *r.BaselineValidationLogLoss {
		t.Fatalf("%+v", r)
	}
	if r.Weights.FactorWeights[string(rating.OfficialRating)] <= rating.V1().FactorWeights[string(rating.OfficialRating)] {
		t.Fatal("the predictive factor should gain weight")
	}
	if r.Weights.FactorWeights[string(rating.RecentForm)] > 0.05 {
		t.Fatal("the uninformative factor should fall to zero")
	}
	if r.Weights.FormInfluence <= rating.V1().FormInfluence {
		t.Fatal("form should be trusted more")
	}
	if r.Weights.ID != "learned-149-150" {
		t.Fatal("promotion must mint a new weights id:", r.Weights.ID)
	}
	if rating.V1().FactorWeights[string(rating.OfficialRating)] != 0.30 {
		t.Fatal("training mutated the preset")
	}
}

func TestKeepsBlendWithinBounds(t *testing.T) {
	cfg := DefaultConfiguration()
	cfg.MinimumRaces, cfg.ValidationRaces, cfg.Epochs = 100, 30, 80
	cfg.MarketExponentRange, cfg.FormInfluenceRange = FloatRange{0.8, 1.2}, FloatRange{0.2, 0.5}
	w := Train(samples(150), rating.V1(), cfg).Weights
	if w.MarketExponent < 0.8 || w.MarketExponent > 1.2 || w.FormInfluence < 0.2 || w.FormInfluence > 0.5 {
		t.Fatalf("%+v", w)
	}
}

func TestConfigurationMatchesSwiftCodable(t *testing.T) {
	out, _ := json.Marshal(DefaultConfiguration())
	var back map[string]any
	_ = json.Unmarshal(out, &back)
	if r, ok := back["marketExponentRange"].([]any); !ok || len(r) != 2 {
		t.Fatal("ClosedRange<Double> encodes as a pair:", string(out))
	}
}

func TestTrainsNewFactorsFromRecentCompatibleSnapshots(t *testing.T) {
	races := samples(600)
	for index := 100; index < len(races); index++ {
		signal := races[index].Snapshot.ZScores[0]
		races[index].Snapshot.FactorIDs = []rating.FactorID{rating.OfficialRating, rating.TrainerRecentStrikeRate}
		races[index].Snapshot.ZScores = [][]float64{{0, 0, 0}, signal}
	}
	report := Train(races, rating.V3(), DefaultConfiguration())
	if report.SettledRaceCount != 500 {
		t.Fatalf("want 500 compatible races, got %d", report.SettledRaceCount)
	}
	if !report.Trained || !report.Promoted || report.Weights.Weight(rating.TrainerRecentStrikeRate) <= 0 {
		t.Fatalf("the newer predictive factor must enter the promoted model: %+v", report)
	}
}

func TestDoesNotGiveWeightsToFactorsWithoutVariation(t *testing.T) {
	report := Train(calibratedSamples(), rating.V3(), DefaultConfiguration())
	if !report.Promoted {
		t.Fatalf("test requires a promoted candidate: %+v", report)
	}
	for _, factor := range []rating.FactorID{rating.Draw, rating.Headgear, rating.TrainerGoingStrikeRate, rating.HorseGoingPlaceRate} {
		if weight := report.Weights.Weight(factor); weight != 0 {
			t.Errorf("%s has no fitting variation but gets weight %g", factor, weight)
		}
	}
}

func TestWaitsForMinimumCompatibleHistory(t *testing.T) {
	races := samples(599)
	for index := 100; index < len(races); index++ {
		races[index].Snapshot.FactorIDs = append(races[index].Snapshot.FactorIDs, rating.TrainerRecentStrikeRate)
		races[index].Snapshot.ZScores = append(races[index].Snapshot.ZScores, []float64{2, -1, -1})
	}
	report := Train(races, rating.V3(), DefaultConfiguration())
	if report.Trained || report.Promoted || report.SettledRaceCount != 499 || report.Weights.ID != "v3" {
		t.Fatalf("older incompatible races must not satisfy the minimum: %+v", report)
	}
}

func TestStopsCompatibleHistoryAtTheLatestGap(t *testing.T) {
	races := samples(600)
	for index := range races {
		if index == 200 {
			continue
		}
		races[index].Snapshot.FactorIDs = append(races[index].Snapshot.FactorIDs, rating.TrainerRecentStrikeRate)
		races[index].Snapshot.ZScores = append(races[index].Snapshot.ZScores, []float64{2, -1, -1})
	}
	report := Train(races, rating.V3(), DefaultConfiguration())
	if report.Trained || report.SettledRaceCount != 399 {
		t.Fatalf("training must use consecutive compatible history: %+v", report)
	}
}

func TestFactorOrderDoesNotChangeCompatibleHistory(t *testing.T) {
	races := samples(500)
	for index := range races {
		if index%2 == 0 {
			races[index].Snapshot.FactorIDs = []rating.FactorID{rating.RecentForm, rating.OfficialRating}
			rows := races[index].Snapshot.ZScores
			races[index].Snapshot.ZScores = [][]float64{rows[1], rows[0]}
		}
	}
	report := Train(races, rating.V3(), DefaultConfiguration())
	if !report.Trained || !report.Promoted || report.SettledRaceCount != 500 {
		t.Fatalf("factor order must not split compatible history: %+v", report)
	}
}

func TestValidationOnlyVariationDoesNotEnableFactor(t *testing.T) {
	races := calibratedSamples()
	for index := 400; index < len(races); index++ {
		for position, factor := range races[index].Snapshot.FactorIDs {
			if factor == rating.TrainerGoingStrikeRate {
				races[index].Snapshot.ZScores[position] = []float64{2, -1, -1}
			}
		}
	}
	report := Train(races, rating.V3(), DefaultConfiguration())
	if !report.Trained || !report.Promoted {
		t.Fatalf("test requires a promoted candidate: %+v", report)
	}
	if report.Weights.Weight(rating.TrainerGoingStrikeRate) != 0 {
		t.Fatal("validation races must not enable a factor without fitting variation")
	}
}
