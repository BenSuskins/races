package service

import (
	"context"
	"time"

	"github.com/bensuskins/races/server/internal/backtest"
	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/importer"
	"github.com/bensuskins/races/server/internal/matching"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
	"github.com/bensuskins/races/server/internal/training"
)

type weightsPort interface {
	InstallManualWeights(context.Context, rating.Weights, time.Time) error
	Weights(context.Context, string) (*rating.Weights, error)
	AllWeights(context.Context) ([]rating.StoredWeights, error)
	WeightsIDsInUse(context.Context) (map[string]int, error)
	ActiveWeights(ctx context.Context) (*rating.Weights, error)
	EnsureWeights(ctx context.Context, w rating.Weights, origin string, at time.Time) (bool, error)
	SetActiveWeights(ctx context.Context, id string) error
}

type jobsPort interface {
	JobRuns(context.Context) ([]domain.JobRun, error)
	Counts(context.Context) domain.Counts
	JobStarted(ctx context.Context, name string, at time.Time)
	JobFinished(ctx context.Context, name string, at time.Time, summary string, jobErr error)
}

type cardsPort interface {
	RacecardsFetchedAt(context.Context, string) (time.Time, bool)
	Courses(context.Context) ([]domain.Course, error)
	SaveCourses(ctx context.Context, courses []domain.Course, at time.Time) error
	SaveRaces(ctx context.Context, races []domain.Race, at time.Time) error
	RacesOn(ctx context.Context, date string) ([]domain.Race, error)
	RacesOffBetween(ctx context.Context, from, to time.Time) ([]domain.Race, error)
	Race(ctx context.Context, id string) (*domain.Race, error)
}

type marketsPort interface {
	SaveMatch(ctx context.Context, m matching.Record) error
	Matches(ctx context.Context, raceIDs []string) (map[string]matching.Record, error)
	LatestSnapshot(ctx context.Context, raceID, kind string) (*domain.MarketSnapshot, error)
	SaveSnapshot(ctx context.Context, raceID, kind string, snap domain.MarketSnapshot) error
	SaveStartingPrices(ctx context.Context, sps map[string]map[int64]float64, at time.Time) error
	StartingPrices(ctx context.Context, marketIDs []string) (map[string]map[int64]float64, error)
}

type tipsPort interface {
	Tips(context.Context, string, string) ([]tracking.RecordedTip, error)
	Tip(ctx context.Context, raceID string) (*tracking.RecordedTip, error)
	SaveTip(ctx context.Context, t tracking.Tip, source string, at time.Time) error
	SaveSealedTip(ctx context.Context, t tracking.Tip, race domain.Race, source string, at time.Time) error
	AwaitingReconciliation(ctx context.Context, now time.Time) ([]tracking.RecordedTip, error)
	AwaitingStartingPrices(ctx context.Context) ([]tracking.RecordedTip, error)
}

type resultsPort interface {
	ResultsOn(context.Context, string) ([]domain.RaceResult, error)
	Result(ctx context.Context, raceID string) (*domain.RaceResult, error)
	ResultFactsKnownBefore(ctx context.Context, cutoff time.Time) ([]domain.RaceResult, error)
	SaveResults(ctx context.Context, results []domain.RaceResult, at time.Time) (int, error)
	SealCard(ctx context.Context, raceID string) (*domain.Race, error)
}

type trainingPort interface {
	TrainingCounts(context.Context) (int, int)
	SaveTrainingSnapshot(ctx context.Context, snap rating.TrainingSnapshot, source string) error
	SetTrainingWinner(ctx context.Context, raceID, winnerID string) (bool, error)
	SettledTrainingSamples(ctx context.Context, from, to time.Time) ([]training.Race, error)
}

type documentsPort interface {
	Backtests(context.Context, int64) ([]backtest.StoredReport, error)
	LoadDocument(ctx context.Context, name string, v any) (bool, error)
	SaveDocument(ctx context.Context, name string, v any, at time.Time) error
	SaveBacktest(ctx context.Context, weightsID string, request, report any, at time.Time) (int64, error)
}

type assessmentsPort interface {
	AssessmentsOn(context.Context, string) (map[string]rating.Assessment, error)
	Assessment(context.Context, string) (*rating.Assessment, error)
	SaveAssessment(context.Context, rating.Assessment) error
}

type TrainingPromotionTx interface {
	EnsureWeights(context.Context, rating.Weights, string, time.Time) (bool, error)
	Weights(context.Context, string) (*rating.Weights, error)
	SetActiveWeights(context.Context, string) error
	SaveDocument(context.Context, string, any, time.Time) error
}

type trainingPromotionPort interface {
	TrainingTransaction(context.Context, func(TrainingPromotionTx) error) error
}

// Persistence groups the independent capabilities used by the application.
type Persistence struct {
	Promotion   trainingPromotionPort
	Imports     importer.Repository
	Weights     weightsPort
	Jobs        jobsPort
	Cards       cardsPort
	Markets     marketsPort
	Tips        tipsPort
	Results     resultsPort
	Training    trainingPort
	Documents   documentsPort
	Assessments assessmentsPort
	History     backtest.History
}
