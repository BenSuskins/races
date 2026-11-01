package service

import (
	"context"

	"github.com/bensuskins/races/server/internal/tracking"
)

// RecordTip joins a tip to its origin in the shared record.
type RecordTip struct {
	tracking.Tip
	Source string `json:"source"`
}

// Record summarizes one population of recorded tips.
type Record struct {
	WeightsID       string          `json:"weightsID,omitempty"`
	ActiveWeightsID string          `json:"activeWeightsID,omitempty"`
	Commission      float64         `json:"commission"`
	Report          tracking.Report `json:"report"`
	RecentTips      []RecordTip     `json:"recentTips"`
	WeightsInUse    map[string]int  `json:"weightsInUse"`
	Sources         map[string]int  `json:"sources"`
	ArchivedRaces   int             `json:"archivedRaces"`
}

// RecordReader provides the data needed to summarize a record.
type RecordReader interface {
	ActiveWeightsID(context.Context) (string, error)
	RecordTips(context.Context, string) ([]RecordTip, error)
	WeightsInUse(context.Context) (map[string]int, error)
	ArchivedRaces(context.Context) int
}

// BuildRecord summarizes the selected weight population, or the active one.
func BuildRecord(ctx context.Context, reader RecordReader, weightsID string, commission float64) (Record, error) {
	activeID, err := reader.ActiveWeightsID(ctx)
	if err != nil {
		return Record{}, err
	}
	if weightsID == "" {
		weightsID = activeID
	}
	rows, err := reader.RecordTips(ctx, weightsID)
	if err != nil {
		return Record{}, err
	}
	tips := make([]tracking.Tip, len(rows))
	sources := map[string]int{}
	recent := make([]RecordTip, 0, min(len(rows), 30))
	for i, row := range rows {
		tips[i] = row.Tip
		sources[row.Source]++
		if len(recent) < 30 && row.Tip.Outcome != nil && row.Tip.Outcome.IsSettled() {
			recent = append(recent, row)
		}
	}
	inUse, _ := reader.WeightsInUse(ctx)
	return Record{WeightsID: weightsID, ActiveWeightsID: activeID, Commission: commission, Report: tracking.Accuracy(tips, commission), RecentTips: recent, WeightsInUse: inUse, Sources: sources, ArchivedRaces: reader.ArchivedRaces(ctx)}, nil
}
