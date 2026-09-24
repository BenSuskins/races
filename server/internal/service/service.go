// Package service is the server's behaviour: the jobs that collect cards,
// markets and results, rate and seal tips, settle them and retrain — the work
// RacesStore, RacecardLoader, MarketLoader and AppEnvironment.refreshResults
// did on the phone.
//
// It never reaches a provider except through the two interfaces below, so the
// whole pipeline is tested against fakes with an injected clock.
package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/httpx"
	"github.com/bensuskins/races/server/internal/matching"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/store"
	"github.com/bensuskins/races/server/internal/tracking"
	"github.com/bensuskins/races/server/internal/training"
)

// RacingData is The Racing API as the service needs it.
type RacingData interface {
	Courses(ctx context.Context, regions ...string) ([]domain.Course, error)
	Racecards(ctx context.Context, day domain.RaceDay, regions ...string) ([]domain.Race, error)
	TodaysResults(ctx context.Context) ([]domain.RaceResult, error)
}

// MarketData is Betfair as the service needs it. Optional: nil means form
// only, which is an ordinary state rather than an error.
type MarketData interface {
	Markets(ctx context.Context, day string, countries ...string) ([]matching.ExchangeMarket, error)
	Prices(ctx context.Context, marketIDs []string) ([]matching.ExchangePrices, error)
	StartingPrices(ctx context.Context, marketIDs []string) (map[string]map[int64]float64, error)
}

// Service owns the jobs. Jobs are serialised by one mutex: a seal and a
// results ingest must never interleave.
type Service struct {
	Store   *store.Store
	Racing  RacingData
	Markets MarketData
	Now     func() time.Time
	Log     *slog.Logger
	// Regions the card is fetched for.
	Regions []string
	// Training is the retraining configuration.
	Training training.Configuration

	mu sync.Mutex
}

const (
	archiveDocument        = "archive"
	trainingReportDocument = "training-report"
	sourceServer           = "server"
)

func New(st *store.Store, racing RacingData, markets MarketData, now func() time.Time, log *slog.Logger) *Service {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.Default()
	}
	return &Service{Store: st, Racing: racing, Markets: markets, Now: now, Log: log, Regions: []string{"gb", "ire"}, Training: training.DefaultConfiguration()}
}

// Bootstrap seeds the preset weights and makes v2 active on a fresh database.
func (s *Service) Bootstrap(ctx context.Context) error {
	now := s.Now()
	for _, w := range rating.Presets() {
		if _, err := s.Store.EnsureWeights(ctx, w, "preset", now); err != nil {
			return err
		}
	}
	if active, err := s.Store.ActiveWeights(ctx); err != nil {
		return err
	} else if active == nil {
		return s.Store.SetActiveWeights(ctx, rating.V2().ID)
	}
	return nil
}

// run records a job's start, end and outcome for /v1/status.
func (s *Service) run(ctx context.Context, name string, fn func() (string, error)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.Store.JobStarted(ctx, name, s.Now())
	summary, err := fn()
	s.Store.JobFinished(ctx, name, s.Now(), summary, err)
	if err != nil {
		s.Log.Warn("job failed", "job", name, "error", err)
	} else {
		s.Log.Info("job done", "job", name, "summary", summary)
	}
	return err
}

func (s *Service) activeRater(ctx context.Context) (rating.Rater, error) {
	w, err := s.Store.ActiveWeights(ctx)
	if err != nil {
		return rating.Rater{}, err
	}
	if w == nil {
		v2 := rating.V2()
		w = &v2
	}
	return rating.NewRater(*w), nil
}

func (s *Service) archive(ctx context.Context) (*tracking.Archive, error) {
	a := tracking.NewArchive()
	if _, err := s.Store.LoadDocument(ctx, archiveDocument, a); err != nil {
		return nil, err
	}
	return a, nil
}

// ArchivedRaceCount is how many results feed the strike-rate factors.
func (s *Service) ArchivedRaceCount(ctx context.Context) int {
	a, err := s.archive(ctx)
	if err != nil {
		return 0
	}
	return a.RaceCount()
}

// MARK: - Cards

// RefreshCourses fetches the course directory.
func (s *Service) RefreshCourses(ctx context.Context) error {
	return s.run(ctx, "courses", func() (string, error) {
		courses, err := s.Racing.Courses(ctx, s.Regions...)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%d courses", len(courses)), s.Store.SaveCourses(ctx, courses, s.Now())
	})
}

// RefreshCards fetches a day's racecards.
func (s *Service) RefreshCards(ctx context.Context, day domain.RaceDay) error {
	return s.run(ctx, "cards-"+string(day), func() (string, error) {
		races, err := s.Racing.Racecards(ctx, day, s.Regions...)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%d races", len(races)), s.Store.SaveRaces(ctx, races, s.Now())
	})
}

// MARK: - Markets

// RefreshMarkets fetches the day's win markets and matches them, recording
// every refusal with its reason.
func (s *Service) RefreshMarkets(ctx context.Context, day domain.RaceDay) error {
	if s.Markets == nil {
		return nil
	}
	return s.run(ctx, "markets-"+string(day), func() (string, error) {
		date := domain.DayStringFor(day, s.Now())
		races, err := s.Store.RacesOn(ctx, date)
		if err != nil || len(races) == 0 {
			return "no races", err
		}
		markets, err := s.Markets.Markets(ctx, date)
		if err != nil {
			return "", err
		}
		report := matching.MatchRaces(races, markets, matching.DefaultTolerances)
		now := s.Now()
		for _, m := range report.Matches {
			ref := m.Reference()
			if err := s.Store.SaveMatch(ctx, store.MatchRow{RaceID: m.RaceID, MatchedAt: now, Reference: &ref}); err != nil {
				return "", err
			}
		}
		for raceID, refusal := range report.Refusals {
			raw, _ := json.Marshal(refusalView(refusal))
			if err := s.Store.SaveMatch(ctx, store.MatchRow{RaceID: raceID, MatchedAt: now, Refusal: raw}); err != nil {
				return "", err
			}
		}
		return fmt.Sprintf("%d matched, %d refused, %d unclaimed", len(report.Matches), len(report.Refusals), len(report.UnclaimedMarketIDs)), nil
	})
}

// RefusalView is what the app shows for a race with no market.
type RefusalView struct {
	matching.Refusal
	DisplayName string `json:"displayName"`
}

func refusalView(r matching.Refusal) RefusalView {
	return RefusalView{Refusal: r, DisplayName: r.DisplayName()}
}

// priced fetches prices for the matched races and joins them onto our horse
// ids. It never fails: no market is an ordinary state. A book with no price at
// all is dropped — "matched a market" and "has prices" are different claims.
func (s *Service) priced(ctx context.Context, races []domain.Race) (map[string]domain.MarketSnapshot, map[string]*domain.MarketReference) {
	snapshots := map[string]domain.MarketSnapshot{}
	references := map[string]*domain.MarketReference{}
	if s.Markets == nil || len(races) == 0 {
		return snapshots, references
	}
	ids := make([]string, len(races))
	for i, r := range races {
		ids[i] = r.ID
	}
	matches, err := s.Store.Matches(ctx, ids)
	if err != nil {
		s.Log.Warn("loading matches", "error", err)
		return snapshots, references
	}
	byMarket := map[string][]string{}
	var marketIDs []string
	for raceID, m := range matches {
		if m.Reference == nil {
			continue
		}
		ref := *m.Reference
		references[raceID] = &ref
		if _, seen := byMarket[ref.MarketID]; !seen {
			marketIDs = append(marketIDs, ref.MarketID)
		}
		byMarket[ref.MarketID] = append(byMarket[ref.MarketID], raceID)
	}
	if len(marketIDs) == 0 {
		return snapshots, references
	}
	books, err := s.Markets.Prices(ctx, marketIDs)
	if err != nil {
		s.Log.Warn("prices", "error", err)
		return snapshots, references
	}
	for _, book := range books {
		for _, raceID := range byMarket[book.MarketID] {
			ref := references[raceID]
			inverse := map[int64]string{}
			for horse, sel := range ref.SelectionIDsByHorseID {
				inverse[sel] = horse
			}
			snap := matching.Snapshot(book, inverse, domain.SourceLiveExchange)
			if hasAnyPrice(snap) {
				snapshots[raceID] = snap
			}
		}
	}
	return snapshots, references
}

func hasAnyPrice(s domain.MarketSnapshot) bool {
	for _, p := range s.Prices {
		if p.HasAnyPrice() {
			return true
		}
	}
	return false
}

// MARK: - Tips

// DraftTips rates every unstarted race on a day with current prices, stores
// the assessment for display and records a draft tip. The whole card, never a
// subset: a ledger of races that looked interesting is a biased sample.
func (s *Service) DraftTips(ctx context.Context, day domain.RaceDay) error {
	return s.run(ctx, "draft-"+string(day), func() (string, error) {
		now := s.Now()
		races, err := s.Store.RacesOn(ctx, domain.DayStringFor(day, now))
		if err != nil {
			return "", err
		}
		var open []domain.Race
		for _, r := range races {
			if off, ok := r.Off(); !ok || now.Before(off) {
				open = append(open, r)
			}
		}
		stored, err := s.rateAndRecord(ctx, open, "display", now)
		return fmt.Sprintf("%d rated, %d stored", len(open), stored), err
	})
}

// SealTips seals every race inside the window before its off. Prices are
// fetched first, never after: recording is what seals a tip, and a tip sealed
// form-only and re-rated with prices later would be a record of something
// nobody was shown.
func (s *Service) SealTips(ctx context.Context) error {
	return s.run(ctx, "seal", func() (string, error) {
		now := s.Now()
		races, err := s.Store.RacesOffBetween(ctx, now, now.Add(tracking.SealWindow+time.Second))
		if err != nil {
			return "", err
		}
		var due []domain.Race
		for _, r := range races {
			row, err := s.Store.Tip(ctx, r.ID)
			if err != nil {
				return "", err
			}
			if row == nil || !row.Tip.IsSealed() {
				due = append(due, r)
			}
		}
		stored, err := s.rateAndRecord(ctx, due, "seal", now)
		return fmt.Sprintf("%d due, %d sealed", len(due), stored), err
	})
}

func (s *Service) rateAndRecord(ctx context.Context, races []domain.Race, kind string, now time.Time) (int, error) {
	if len(races) == 0 {
		return 0, nil
	}
	rater, err := s.activeRater(ctx)
	if err != nil {
		return 0, err
	}
	archive, err := s.archive(ctx)
	if err != nil {
		return 0, err
	}
	snapshots, references := s.priced(ctx, races)
	stored := 0
	for _, race := range races {
		var market *domain.MarketSnapshot
		if snap, ok := snapshots[race.ID]; ok {
			market = &snap
			if err := s.Store.SaveSnapshot(ctx, race.ID, kind, snap); err != nil {
				return stored, err
			}
		}
		a := rater.Rate(race, market, archive, now)
		if err := s.Store.SaveAssessment(ctx, a); err != nil {
			return stored, err
		}
		candidate, ok := tracking.NewTip(a, race, references[race.ID], now)
		if !ok {
			continue
		}
		var existing *tracking.Tip
		if row, err := s.Store.Tip(ctx, race.ID); err != nil {
			return stored, err
		} else if row != nil {
			existing = &row.Tip
		}
		outcome, tip := tracking.Decide(existing, candidate, now)
		if tip == nil {
			continue
		}
		if err := s.Store.SaveTip(ctx, *tip, sourceServer, now); err != nil {
			return stored, err
		}
		stored++
		// The inputs the tip was sealed on are what training learns from.
		if outcome == tracking.Sealed && a.TrainingSnapshot != nil {
			if err := s.Store.SaveTrainingSnapshot(ctx, *a.TrainingSnapshot, sourceServer); err != nil {
				return stored, err
			}
		}
	}
	return stored, nil
}

// MARK: - Results

// Ingestion is what one results pass did.
type Ingestion struct {
	ResultsStored  int  `json:"resultsStored"`
	RacesArchived  int  `json:"racesArchived"`
	TipsSettled    int  `json:"tipsSettled"`
	SamplesSettled int  `json:"samplesSettled"`
	StartingPrices int  `json:"startingPrices"`
	PricesFailed   bool `json:"startingPricesFailed"`
}

// CollectResults is the single path for results. The free endpoint is
// today-only, so this runs through the evening. Betfair's settled prices are a
// second, independent call whose failure costs the ROI figure and nothing else.
func (s *Service) CollectResults(ctx context.Context) (Ingestion, error) {
	var ing Ingestion
	err := s.run(ctx, "results", func() (string, error) {
		now := s.Now()
		results, err := s.Racing.TodaysResults(ctx)
		if err != nil {
			return "", err
		}
		if ing.ResultsStored, err = s.Store.SaveResults(ctx, results, now); err != nil {
			return "", err
		}
		// Results can also be re-read for races settled on earlier days.
		byRace := map[string]domain.RaceResult{}
		for _, r := range results {
			byRace[r.ID] = r
		}

		archive, err := s.archive(ctx)
		if err != nil {
			return "", err
		}
		for _, r := range results {
			if archive.Ingest(r) {
				ing.RacesArchived++
			}
		}
		if ing.RacesArchived > 0 {
			if err := s.Store.SaveDocument(ctx, archiveDocument, archive, now); err != nil {
				return "", err
			}
		}

		waiting, err := s.Store.AwaitingReconciliation(ctx, now)
		if err != nil {
			return "", err
		}
		sps := s.startingPrices(ctx, waiting, now, &ing)
		for _, row := range waiting {
			tip := row.Tip
			var result *domain.RaceResult
			if r, ok := byRace[tip.RaceID]; ok {
				result = &r
			} else if stored, err := s.Store.Result(ctx, tip.RaceID); err == nil && stored != nil {
				result = stored
			}
			var betfair map[string]float64
			if tip.MarketReference != nil {
				betfair = tip.MarketReference.StartingPrices(sps)
			}
			settled := tracking.Settle(tip, result, betfair, false, now)
			if err := s.Store.SaveTip(ctx, settled, row.Source, now); err != nil {
				return "", err
			}
			if settled.Outcome != nil && (settled.Outcome.IsSettled() || settled.Outcome.IsVoid()) {
				ing.TipsSettled++
			}
			if settled.Outcome != nil && settled.Outcome.IsSettled() && result != nil {
				if w := result.Winner(); w != nil {
					if ok, err := s.Store.SetTrainingWinner(ctx, tip.RaceID, w.HorseID); err != nil {
						return "", err
					} else if ok {
						ing.SamplesSettled++
					}
				}
			}
		}
		return fmt.Sprintf("%d results, %d archived, %d tips settled, %d samples", ing.ResultsStored, ing.RacesArchived, ing.TipsSettled, ing.SamplesSettled), nil
	})
	return ing, err
}

func (s *Service) startingPrices(ctx context.Context, waiting []store.TipRow, now time.Time, ing *Ingestion) map[string]map[int64]float64 {
	tips := make([]tracking.Tip, len(waiting))
	for i, w := range waiting {
		tips[i] = w.Tip
	}
	ids := tracking.MarketIDsAwaitingStartingPrice(tips, now)
	if len(ids) == 0 || s.Markets == nil {
		stored, _ := s.Store.StartingPrices(ctx, ids)
		return stored
	}
	fresh, err := s.Markets.StartingPrices(ctx, ids)
	if err != nil {
		// Swallowed on purpose: losing the strike rate as well would be the bug.
		ing.PricesFailed = true
		s.Log.Warn("starting prices", "error", err)
	} else {
		for _, m := range fresh {
			ing.StartingPrices += len(m)
		}
		s.Store.SaveStartingPrices(ctx, fresh, now)
	}
	stored, _ := s.Store.StartingPrices(ctx, ids)
	return stored
}

// MARK: - Training

// Train re-fits the weights over every settled sample. Promotion mints a new
// weights id and makes it active; the record splits by id from then on.
func (s *Service) Train(ctx context.Context) (training.Report, error) {
	var report training.Report
	err := s.run(ctx, "train", func() (string, error) {
		now := s.Now()
		current, err := s.Store.ActiveWeights(ctx)
		if err != nil || current == nil {
			return "", errors.Join(err, errors.New("no active weights"))
		}
		samples, err := s.Store.SettledTrainingSamples(ctx, time.Time{}, time.Time{})
		if err != nil {
			return "", err
		}
		report = training.Train(samples, *current, s.Training)
		if err := s.Store.SaveDocument(ctx, trainingReportDocument, report, now); err != nil {
			return "", err
		}
		if report.Promoted {
			if _, err := s.Store.EnsureWeights(ctx, report.Weights, "trained", now); err != nil {
				return "", err
			}
			if err := s.Store.SetActiveWeights(ctx, report.Weights.ID); err != nil {
				return "", err
			}
		}
		return fmt.Sprintf("%d samples, trained=%t, promoted=%t", report.SettledRaceCount, report.Trained, report.Promoted), nil
	})
	return report, err
}

// LastTrainingReport, if any.
func (s *Service) LastTrainingReport(ctx context.Context) *training.Report {
	var r training.Report
	if ok, _ := s.Store.LoadDocument(ctx, trainingReportDocument, &r); ok {
		return &r
	}
	return nil
}

// IsExpected reports an error that is a missing tier or provider.
func IsExpected(err error) bool {
	var e *httpx.Error
	return errors.As(err, &e) && e.IsExpectedLimitation()
}
