package service

import "context"

type recordStore struct{ service *Service }

func (r recordStore) ActiveWeightsID(ctx context.Context) (string, error) {
	weights, err := r.service.ports.Weights.ActiveWeights(ctx)
	if err != nil || weights == nil {
		return "", err
	}
	return weights.ID, nil
}

func (r recordStore) RecordTips(ctx context.Context, weightsID string) ([]RecordTip, error) {
	rows, err := r.service.ports.Tips.Tips(ctx, weightsID, "")
	if err != nil {
		return nil, err
	}
	tips := make([]RecordTip, len(rows))
	for i, row := range rows {
		tips[i] = RecordTip{Tip: row.Tip, Source: row.Source}
	}
	return tips, nil
}

func (r recordStore) WeightsInUse(ctx context.Context) (map[string]int, error) {
	return r.service.ports.Weights.WeightsIDsInUse(ctx)
}

func (r recordStore) ArchivedRaces(ctx context.Context) int { return r.service.ArchivedRaceCount(ctx) }

// Record returns the accuracy report for one weight population.
func (s *Service) Record(ctx context.Context, weightsID string, commission float64) (Record, error) {
	return BuildRecord(ctx, recordStore{service: s}, weightsID, commission)
}
