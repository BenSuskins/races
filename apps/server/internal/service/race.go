package service

import (
	"context"
	"encoding/json"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/matching"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
)

type RaceDetail struct {
	Race       domain.Race            `json:"race"`
	Assessment *rating.Assessment     `json:"assessment,omitempty"`
	Tip        *tracking.Tip          `json:"tip,omitempty"`
	Result     *domain.RaceResult     `json:"result,omitempty"`
	Snapshot   *domain.MarketSnapshot `json:"snapshot,omitempty"`
	Refusal    json.RawMessage        `json:"refusal,omitempty"`
}

type RaceReader interface {
	Race(context.Context, string) (*domain.Race, error)
	Assessment(context.Context, string) (*rating.Assessment, error)
	Tip(context.Context, string) (*tracking.RecordedTip, error)
	Result(context.Context, string) (*domain.RaceResult, error)
	LatestSnapshot(context.Context, string, string) (*domain.MarketSnapshot, error)
	Matches(context.Context, []string) (map[string]matching.Record, error)
}

func ReadRace(ctx context.Context, reader RaceReader, id string) (*RaceDetail, error) {
	race, err := reader.Race(ctx, id)
	if err != nil || race == nil {
		return nil, err
	}
	detail := &RaceDetail{Race: *race}
	detail.Assessment, _ = reader.Assessment(ctx, id)
	if tip, _ := reader.Tip(ctx, id); tip != nil {
		detail.Tip = &tip.Tip
	}
	detail.Result, _ = reader.Result(ctx, id)
	if detail.Tip != nil && detail.Tip.IsSealed() {
		detail.Snapshot, _ = reader.LatestSnapshot(ctx, id, "seal")
	}
	if detail.Snapshot == nil {
		detail.Snapshot, _ = reader.LatestSnapshot(ctx, id, "display")
	}
	matches, _ := reader.Matches(ctx, []string{id})
	detail.Refusal = matches[id].Refusal
	return detail, nil
}
