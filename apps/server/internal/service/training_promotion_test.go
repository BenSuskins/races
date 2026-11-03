package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/store"
	"github.com/bensuskins/races/server/internal/training"
)

func TestTrainingPromotionRejectsConflictingWeightIDWithoutPublishingReport(t *testing.T) {
	service, _, _, _, _, _ := setup(t)
	ctx := context.Background()
	now := time.Date(2026, 9, 22, 12, 0, 0, 0, time.UTC)
	original := rating.V3().Clone()
	original.ID = "learned-collision"
	if _, err := service.ports.Weights.EnsureWeights(ctx, original, "trained", now); err != nil {
		t.Fatal(err)
	}
	previous := training.Report{SettledRaceCount: 12}
	if err := service.ports.Documents.SaveDocument(ctx, trainingReportDocument, previous, now); err != nil {
		t.Fatal(err)
	}
	candidate := original.Clone()
	candidate.FormInfluence = 0.123
	report := training.Report{Promoted: true, Weights: candidate}
	if err := service.publishTrainingReport(ctx, report, now); err == nil {
		t.Fatal("conflicting weights were promoted")
	}
	active, err := service.ports.Weights.ActiveWeights(ctx)
	if err != nil || active == nil || active.ID != "v3" {
		t.Fatalf("active weights changed: %+v, %v", active, err)
	}
	if latest := service.LastTrainingReport(ctx); latest == nil || latest.SettledRaceCount != 12 {
		t.Fatalf("failed promotion replaced report: %+v", latest)
	}
}

func TestTrainingPromotionCanReuseIdenticalWeights(t *testing.T) {
	service, _, _, _, _, _ := setup(t)
	ctx := context.Background()
	now := time.Date(2026, 9, 22, 12, 0, 0, 0, time.UTC)
	candidate := rating.V3().Clone()
	candidate.ID = "learned-existing"
	if _, err := service.ports.Weights.EnsureWeights(ctx, candidate, "trained", now); err != nil {
		t.Fatal(err)
	}
	if err := service.publishTrainingReport(ctx, training.Report{Promoted: true, Weights: candidate}, now); err != nil {
		t.Fatal(err)
	}
	active, err := service.ports.Weights.ActiveWeights(ctx)
	if err != nil || active == nil || active.ID != candidate.ID {
		t.Fatalf("identical weights not activated: %+v, %v", active, err)
	}
}

type failingReportTransaction struct{ TrainingPromotionTx }

func (transaction failingReportTransaction) SaveDocument(context.Context, string, any, time.Time) error {
	return errors.New("report write failed")
}

type failingPromotionStore struct{ *store.Store }

func (storage failingPromotionStore) TrainingTransaction(ctx context.Context, run func(TrainingPromotionTx) error) error {
	return storage.Store.Tx(ctx, func(transaction *store.Tx) error {
		return run(failingReportTransaction{transaction})
	})
}

func TestTrainingPromotionKeepsOldStateWhenReportWriteFails(t *testing.T) {
	service, _, _, _, _, _ := setup(t)
	ctx := context.Background()
	now := time.Date(2026, 9, 22, 12, 0, 0, 0, time.UTC)
	previous := training.Report{SettledRaceCount: 12}
	if err := service.ports.Documents.SaveDocument(ctx, trainingReportDocument, previous, now); err != nil {
		t.Fatal(err)
	}
	storage := testStore(service)
	service.ports.Promotion = failingPromotionStore{storage}
	candidate := rating.V3().Clone()
	candidate.ID = "candidate"
	if err := service.publishTrainingReport(ctx, training.Report{Promoted: true, Weights: candidate}, now); err == nil {
		t.Fatal("expected report write failure")
	}
	active, err := storage.ActiveWeights(ctx)
	if err != nil || active == nil || active.ID != "v3" {
		t.Fatalf("active weights changed: %+v, %v", active, err)
	}
	stored, err := storage.Weights(ctx, candidate.ID)
	if err != nil || stored != nil {
		t.Fatalf("candidate was retained: %+v, %v", stored, err)
	}
	if latest := service.LastTrainingReport(ctx); latest == nil || latest.SettledRaceCount != 12 {
		t.Fatalf("report changed: %+v", latest)
	}
}
