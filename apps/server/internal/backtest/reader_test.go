package backtest

import (
	"context"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
	"github.com/bensuskins/races/server/internal/training"
)

type emptyReader struct{}

func (emptyReader) Tips(context.Context, string, string) ([]tracking.RecordedTip, error) {
	return nil, nil
}
func (emptyReader) SealCard(context.Context, string) (*domain.Race, error)     { return nil, nil }
func (emptyReader) Result(context.Context, string) (*domain.RaceResult, error) { return nil, nil }
func (emptyReader) ResultFactsKnownBefore(context.Context, time.Time) ([]domain.RaceResult, error) {
	return nil, nil
}
func (emptyReader) LatestSnapshot(context.Context, string, string) (*domain.MarketSnapshot, error) {
	return nil, nil
}
func (emptyReader) StartingPrices(context.Context, []string) (map[string]map[int64]float64, error) {
	return nil, nil
}
func (emptyReader) SettledTrainingSamples(context.Context, time.Time, time.Time) ([]training.Race, error) {
	return nil, nil
}

func TestRunAcceptsHistoryPort(t *testing.T) {
	report, err := Run(context.Background(), emptyReader{}, rating.V3(), Request{})
	if err != nil {
		t.Fatal(err)
	}
	if report.WeightsID != rating.V3().ID {
		t.Fatalf("weights ID = %q", report.WeightsID)
	}
}
