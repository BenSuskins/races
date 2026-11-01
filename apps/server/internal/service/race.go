package service

import (
	"context"
	"encoding/json"

	"github.com/bensuskins/races/server/internal/domain"
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
	Tip(context.Context, string) (*tracking.Tip, error)
	Result(context.Context, string) (*domain.RaceResult, error)
	Snapshot(context.Context, string, string) (*domain.MarketSnapshot, error)
	Refusal(context.Context, string) ([]byte, error)
}

func ReadRace(ctx context.Context, reader RaceReader, id string) (*RaceDetail, error) {
	race, err := reader.Race(ctx, id)
	if err != nil || race == nil {
		return nil, err
	}
	detail := &RaceDetail{Race: *race}
	detail.Assessment, _ = reader.Assessment(ctx, id)
	detail.Tip, _ = reader.Tip(ctx, id)
	detail.Result, _ = reader.Result(ctx, id)
	if detail.Tip != nil && detail.Tip.IsSealed() {
		detail.Snapshot, _ = reader.Snapshot(ctx, id, "seal")
	}
	if detail.Snapshot == nil {
		detail.Snapshot, _ = reader.Snapshot(ctx, id, "display")
	}
	detail.Refusal, _ = reader.Refusal(ctx, id)
	return detail, nil
}
