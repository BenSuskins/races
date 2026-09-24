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
