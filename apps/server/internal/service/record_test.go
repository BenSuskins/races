package service

import (
	"context"
	"errors"
	"testing"

	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
)

type fakeRecordReader struct {
	active   string
	tips     []tracking.RecordedTip
	used     map[string]int
	archived int
	err      error
}

func (f fakeRecordReader) ActiveWeights(context.Context) (*rating.Weights, error) {
	if f.err != nil {
		return nil, f.err
	}
	return &rating.Weights{ID: f.active}, nil
}
func (f fakeRecordReader) Tips(context.Context, string, string) ([]tracking.RecordedTip, error) {
	return f.tips, nil
}
func (f fakeRecordReader) WeightsIDsInUse(context.Context) (map[string]int, error) {
	return f.used, nil
}
func (f fakeRecordReader) ArchivedRaces(context.Context) int { return f.archived }

func TestRecordUsesActiveWeightsAndCountsSettledTips(t *testing.T) {
	reader := fakeRecordReader{active: "active", archived: 4, used: map[string]int{"active": 2}, tips: []tracking.RecordedTip{
		{Tip: tracking.Tip{RaceID: "settled", Outcome: &tracking.Outcome{Kind: tracking.Won}}, Source: "server"},
		{Tip: tracking.Tip{RaceID: "pending"}, Source: "server"},
	}}
	got, err := BuildRecord(context.Background(), reader, "", tracking.DefaultCommission)
	if err != nil {
		t.Fatal(err)
	}
	if got.WeightsID != "active" || got.ActiveWeightsID != "active" || got.ArchivedRaces != 4 || got.Sources["server"] != 2 || len(got.RecentTips) != 1 || got.RecentTips[0].RaceID != "settled" {
		t.Fatalf("unexpected record: %+v", got)
	}
}

func TestRecordReturnsActiveWeightsError(t *testing.T) {
	expected := errors.New("unavailable")
	_, err := BuildRecord(context.Background(), fakeRecordReader{err: expected}, "", tracking.DefaultCommission)
	if !errors.Is(err, expected) {
		t.Fatalf("got %v", err)
	}
}
