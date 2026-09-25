package service

import (
	"context"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
)

// Plan is what the scheduler should run at one London minute. Pure, so the
// timetable is tested without a clock.
type Plan struct {
	Courses, CardsToday, CardsTomorrow, MarketsToday, MarketsTomorrow bool
	DraftToday, DraftTomorrow, Seal, Results, Train, Backtest         bool
}

// PlanFor is the timetable:
//
//   - every minute: seal anything inside the five-minute window;
//   - every 15 minutes, 06:00–22:59: today's card, markets and drafts;
//   - hourly, 06:00–22:00: tomorrow's card, markets and drafts;
//   - every 15 minutes from 12:00, and at 23:55: today's results — the free
//     endpoint is today-only, so the last pass of the day matters most;
//   - 06:00: the course directory; 02:45: baseline replay; 03:00: retraining.
func PlanFor(t time.Time) Plan {
	l := t.In(domain.London)
	h, m := l.Hour(), l.Minute()
	daytime := h >= 6 && h <= 22
	quarter := m%15 == 0
	p := Plan{Seal: true}
	if daytime && quarter {
		p.CardsToday, p.MarketsToday, p.DraftToday = true, true, true
	}
	if daytime && m == 0 {
		p.CardsTomorrow, p.MarketsTomorrow, p.DraftTomorrow = true, true, true
	}
	if (h >= 12 && quarter) || (h == 23 && m == 55) {
		p.Results = true
	}
	p.Courses = h == 6 && m == 0
	p.Train = h == 3 && m == 0
	p.Backtest = h == 2 && m == 45
	return p
}

// Everything is the start-up plan: catch up on all of it at once.
var Everything = Plan{Courses: true, CardsToday: true, CardsTomorrow: true, MarketsToday: true, MarketsTomorrow: true, DraftToday: true, DraftTomorrow: true, Seal: true, Results: true}

// Execute runs a plan in dependency order: cards before markets before drafts.
// Each step's failure is recorded and does not stop the others.
func (s *Service) Execute(ctx context.Context, p Plan) {
	step := func(on bool, fn func() error) {
		if on && ctx.Err() == nil {
			_ = fn()
		}
	}
	step(p.Courses, func() error { return s.RefreshCourses(ctx) })
	step(p.CardsToday, func() error { return s.RefreshCards(ctx, domain.Today) })
	step(p.CardsTomorrow, func() error { return s.RefreshCards(ctx, domain.Tomorrow) })
	step(p.MarketsToday, func() error { return s.RefreshMarkets(ctx, domain.Today) })
	step(p.MarketsTomorrow, func() error { return s.RefreshMarkets(ctx, domain.Tomorrow) })
	step(p.Seal, func() error { return s.SealTips(ctx) })
	step(p.DraftToday, func() error { return s.DraftTips(ctx, domain.Today) })
	step(p.DraftTomorrow, func() error { return s.DraftTips(ctx, domain.Tomorrow) })
	step(p.Results, func() error { _, err := s.CollectResults(ctx); return err })
	step(p.Train, func() error { _, err := s.Train(ctx); return err })
	step(p.Backtest, func() error { _, _, err := s.BaselineBacktest(ctx); return err })
}

// Run executes the start-up plan, then ticks on each wall-clock minute until
// ctx is cancelled.
func (s *Service) Run(ctx context.Context) {
	s.Execute(ctx, Everything)
	for {
		now := time.Now()
		next := now.Truncate(time.Minute).Add(time.Minute)
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Until(next)):
			s.Execute(ctx, PlanFor(s.Now()))
		}
	}
}
