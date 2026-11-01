package service

import (
	"context"
	"errors"

	"github.com/bensuskins/races/server/internal/backtest"
	"github.com/bensuskins/races/server/internal/rating"
)

var ErrWeightsNotFound = errors.New("No such weights.")

type InvalidBacktest struct{ Message string }

func (e InvalidBacktest) Error() string { return e.Message }

// RunBacktest evaluates and stores a report or a sweep over one corpus.
func (s *Service) RunBacktest(ctx context.Context, request backtest.Request) (map[string]any, error) {
	var weights *rating.Weights
	switch {
	case request.Weights != nil:
		if request.Weights.ID == "" {
			return nil, InvalidBacktest{Message: "Supplied weights need an id."}
		}
		if err := rating.ValidateManualWeights(*request.Weights); err != nil {
			return nil, InvalidBacktest{Message: err.Error()}
		}
		weights = request.Weights
	case request.WeightsID != "":
		weights, _ = s.ports.Weights.Weights(ctx, request.WeightsID)
	default:
		weights, _ = s.ports.Weights.ActiveWeights(ctx)
	}
	if weights == nil {
		return nil, ErrWeightsNotFound
	}
	if len(request.Variants) > 0 {
		sweep := backtest.SweepReport{Reports: make([]backtest.VariantReport, 0, len(request.Variants))}
		seen := map[string]bool{}
		for _, variant := range request.Variants {
			if seen[variant.Name] {
				return nil, InvalidBacktest{Message: "Sweep variant names must be unique."}
			}
			seen[variant.Name] = true
			candidate, err := backtest.ApplyOverrides(*weights, variant)
			if err != nil {
				return nil, InvalidBacktest{Message: err.Error()}
			}
			variantRequest := request
			variantRequest.Variants = nil
			variantRequest.Weights = nil
			variantRequest.WeightsID = weights.ID
			report, err := backtest.Run(ctx, s.ports.History, candidate, variantRequest)
			if err != nil {
				return nil, err
			}
			if sweep.SharedCorpusID == "" {
				sweep.SharedCorpusID = report.CorpusID
			} else if sweep.SharedCorpusID != report.CorpusID {
				return nil, errors.New("sweep variants used different race sets")
			}
			sweep.Reports = append(sweep.Reports, backtest.VariantReport{Name: variant.Name, Report: report})
		}
		id, err := s.ports.Documents.SaveBacktest(ctx, weights.ID, request, sweep, s.Now())
		if err != nil {
			return nil, err
		}
		return map[string]any{"id": id, "sweep": sweep}, nil
	}
	report, err := backtest.Run(ctx, s.ports.History, *weights, request)
	if err != nil {
		return nil, err
	}
	id, err := s.ports.Documents.SaveBacktest(ctx, weights.ID, request, report, s.Now())
	if err != nil {
		return nil, err
	}
	return map[string]any{"id": id, "report": report}, nil
}

// Backtests returns saved back-tests, newest first.
func (s *Service) Backtests(ctx context.Context, id int64) ([]backtest.StoredReport, error) {
	rows, err := s.ports.Documents.Backtests(ctx, id)
	if err == nil && rows == nil {
		rows = []backtest.StoredReport{}
	}
	return rows, err
}
