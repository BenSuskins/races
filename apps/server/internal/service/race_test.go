package service

import (
	"context"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/matching"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
)

type fakeRaceReader struct {
	race      *domain.Race
	tip       *tracking.Tip
	snapshots []string
}

func (f *fakeRaceReader) Race(context.Context, string) (*domain.Race, error) { return f.race, nil }
func (f *fakeRaceReader) Assessment(context.Context, string) (*rating.Assessment, error) {
	return nil, nil
}
func (f *fakeRaceReader) Tip(context.Context, string) (*tracking.RecordedTip, error) {
	if f.tip == nil {
		return nil, nil
	}
	return &tracking.RecordedTip{Tip: *f.tip}, nil
}
func (f *fakeRaceReader) Result(context.Context, string) (*domain.RaceResult, error) { return nil, nil }
func (f *fakeRaceReader) LatestSnapshot(_ context.Context, _ string, kind string) (*domain.MarketSnapshot, error) {
	f.snapshots = append(f.snapshots, kind)
	if kind == "seal" {
		return &domain.MarketSnapshot{}, nil
	}
	return nil, nil
}
func (f *fakeRaceReader) Matches(context.Context, []string) (map[string]matching.Record, error) {
	return nil, nil
}

func TestRaceDetailUsesSealSnapshotForSealedTip(t *testing.T) {
	reader := &fakeRaceReader{race: &domain.Race{ID: "race"}, tip: &tracking.Tip{SealedAt: domain.Ptr(time.Unix(1800000000, 0))}}
	detail, err := ReadRace(context.Background(), reader, "race")
	if err != nil || detail == nil || detail.Snapshot == nil || len(reader.snapshots) != 1 || reader.snapshots[0] != "seal" {
		t.Fatalf("detail=%+v snapshots=%v err=%v", detail, reader.snapshots, err)
	}
}
