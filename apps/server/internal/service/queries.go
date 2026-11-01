package service

import (
	"context"

	"github.com/bensuskins/races/server/internal/domain"
)

func (s *Service) Courses(ctx context.Context) ([]domain.Course, error) {
	courses, err := s.ports.Cards.Courses(ctx)
	if err == nil && courses == nil {
		courses = []domain.Course{}
	}
	return courses, err
}

func (s *Service) Tips(ctx context.Context, weightsID, date string) ([]RecordTip, error) {
	rows, err := s.ports.Tips.Tips(ctx, weightsID, date)
	if err != nil {
		return nil, err
	}
	tips := make([]RecordTip, len(rows))
	for i, row := range rows {
		tips[i] = RecordTip{Tip: row.Tip, Source: row.Source}
	}
	return tips, nil
}
