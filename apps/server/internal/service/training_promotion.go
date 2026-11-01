package service

import (
	"context"
	"fmt"
	"reflect"
	"time"

	"github.com/bensuskins/races/server/internal/training"
)

func (s *Service) publishTrainingReport(ctx context.Context, report training.Report, now time.Time) error {
	if report.Promoted {
		inserted, err := s.ports.Weights.EnsureWeights(ctx, report.Weights, "trained", now)
		if err != nil {
			return err
		}
		if !inserted {
			stored, err := s.ports.Weights.Weights(ctx, report.Weights.ID)
			if err != nil {
				return err
			}
			if stored == nil || !reflect.DeepEqual(*stored, report.Weights) {
				return fmt.Errorf("training: weights ID %q already names another set", report.Weights.ID)
			}
		}
		if err := s.ports.Weights.SetActiveWeights(ctx, report.Weights.ID); err != nil {
			return err
		}
	}
	return s.ports.Documents.SaveDocument(ctx, trainingReportDocument, report, now)
}
