package training

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
)

func calibratedSamples() []Race {
	result := make([]Race, 500)
	for index := range result {
		winner := "a"
		if index%10 >= 6 {
			winner = "b"
		}
		if index%10 == 9 {
			winner = "c"
		}
		rows := make([][]float64, len(rating.AllFactors))
		for factorIndex, factor := range rating.AllFactors {
			rows[factorIndex] = []float64{0, 0, 0}
			if factor == rating.OfficialRating || factor == rating.HandicapBandPosition {
				rows[factorIndex] = []float64{2, -1, -1}
			}
		}
		result[index] = Race{Snapshot: rating.TrainingSnapshot{
			RaceID: fmt.Sprintf("calibrated-%d", index), CreatedAt: domain.At(time.Unix(int64(index), 0)),
			RunnerIDs: []string{"a", "b", "c"}, MarketProbabilities: []float64{0.6, 0.3, 0.1},
			FactorIDs: rating.AllFactors, ZScores: rows,
		}, WinnerID: winner}
	}
	return result
}

func TestExportedCandidateMatchesValidation(t *testing.T) {
	samples := calibratedSamples()
	report := Train(samples, rating.V3(), DefaultConfiguration())
	if !report.Promoted {
		t.Fatal("test requires a promoted candidate")
	}
	actual := LogLoss(samples[400:], report.Weights)
	t.Logf("reported candidate loss %.12f; exported weights loss %.12f", *report.CandidateValidationLogLoss, actual)
	if math.Abs(actual-*report.CandidateValidationLogLoss) > 1e-12 {
		t.Error("the exported candidate differs from the candidate evaluated for promotion")
	}
}

func TestPromotionHonoursMarketGate(t *testing.T) {
	samples := calibratedSamples()
	for index := 0; index < 400; index++ {
		samples[index].WinnerID = "a"
		if index%10 >= 7 {
			samples[index].WinnerID = "b"
		}
		if index%10 == 9 {
			samples[index].WinnerID = "c"
		}
	}
	report := Train(samples, rating.V3(), DefaultConfiguration())
	market := LogLoss(samples[400:], rating.MarketOnly())
	if !report.Trained || report.CandidateValidationLogLoss == nil ||
		*report.CandidateValidationLogLoss+DefaultConfiguration().MinimumImprovement >= *report.BaselineValidationLogLoss ||
		*report.CandidateValidationLogLoss <= market+0.005 {
		t.Fatalf("test requires a candidate that improves the model but fails the market gate: %+v", report)
	}
	actual := LogLoss(samples[400:], report.Weights)
	t.Logf("promoted=%t; reported baseline %.12f; actual baseline %.12f; candidate %.12f; market %.12f", report.Promoted, *report.BaselineValidationLogLoss, LogLoss(samples[400:], rating.V3()), actual, market)
	if report.Promoted && actual > market+0.005 {
		t.Error("promotion accepts a candidate that fails the documented market gate")
	}
}
