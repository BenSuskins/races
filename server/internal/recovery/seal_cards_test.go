package recovery

import (
	"context"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/racingapi"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/store"
	"github.com/bensuskins/races/server/internal/tracking"
)

const racecardPayload = `{"racecards":[{"race_id":"race-1","course":"Ascot","date":"2026-09-20","off_time":"2:30","off_dt":"2026-09-20T14:30:00+01:00","race_name":"Test Handicap","distance_f":"8.0","region":"GB","race_class":"Class 3","type":"Flat","field_size":"2","going":"Good","surface":"Turf","runners":[{"horse_id":"horse-1","horse":"Runner One","number":"1","draw":"1","age":"5","ofr":"90","lbs":"130","form":"111"},{"horse_id":"horse-2","horse":"Runner Two","number":"2","draw":"2","age":"4","ofr":"80","lbs":"128","form":"000"}]}]}`

func recoveryStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func seedLegacyTip(t *testing.T, st *store.Store, tipPayload, retainedPayload string, fetchedAt, sealedAt time.Time) tracking.Tip {
	t.Helper()
	ctx := context.Background()
	racecards, err := racingapi.ParseRacecards([]byte(tipPayload), fetchedAt)
	if err != nil || len(racecards) != 1 {
		t.Fatalf("parse racecard: %v, %d races", err, len(racecards))
	}
	weights := rating.V3()
	if _, err := st.EnsureWeights(ctx, weights, "preset", sealedAt); err != nil {
		t.Fatal(err)
	}
	assessment := rating.NewRater(weights).Rate(racecards[0], nil, tracking.NewArchive(), sealedAt)
	tip, ok := tracking.NewTip(assessment, racecards[0], nil, sealedAt)
	if !ok {
		t.Fatal("expected a tip")
	}
	tip.SealedAt = domain.Ptr(sealedAt)
	if err := st.SaveTip(ctx, tip, "server", sealedAt); err != nil {
		t.Fatal(err)
	}
	if err := st.SavePayload(ctx, "racingapi", "GET", racecardsPath, "day=today", 200, []byte(retainedPayload), fetchedAt); err != nil {
		t.Fatal(err)
	}
	return tip
}

func TestSealCardsDryRunAndApplyOnlyExactTipMatch(t *testing.T) {
	ctx := context.Background()
	st := recoveryStore(t)
	fetchedAt := time.Date(2026, 9, 20, 13, 25, 0, 0, time.UTC)
	sealedAt := fetchedAt.Add(2 * time.Minute)
	tip := seedLegacyTip(t, st, racecardPayload, racecardPayload, fetchedAt, sealedAt)

	dryRun, err := SealCards(ctx, st, false, sealedAt.Add(time.Hour))
	if err != nil || dryRun.TipsChecked != 1 || dryRun.Recoverable != 1 || dryRun.Recovered != 0 {
		t.Fatalf("dry run did not identify one verified card: %+v, %v", dryRun, err)
	}
	if card, err := st.SealCard(ctx, tip.RaceID); err != nil || card != nil {
		t.Fatalf("dry run wrote a card: %+v, %v", card, err)
	}

	applied, err := SealCards(ctx, st, true, sealedAt.Add(time.Hour))
	if err != nil || applied.Recovered != 1 || applied.Recoverable != 0 {
		t.Fatalf("apply did not recover one verified card: %+v, %v", applied, err)
	}
	card, err := st.SealCard(ctx, tip.RaceID)
	if err != nil || card == nil || card.Name != "Test Handicap" {
		t.Fatalf("recovered card missing: %+v, %v", card, err)
	}
	if !card.OffDateTime.Equal(racecardsOffTime(t, fetchedAt)) {
		t.Fatalf("recovered card has wrong off time: %+v", card.OffDateTime)
	}
	secondRun, err := SealCards(ctx, st, false, sealedAt.Add(2*time.Hour))
	if err != nil || secondRun.TipsChecked != 0 {
		t.Fatalf("existing card was reconsidered: %+v, %v", secondRun, err)
	}
}

func TestSealCardsRejectsTipMismatchAndNonPriorPayload(t *testing.T) {
	ctx := context.Background()
	t.Run("mismatch", func(t *testing.T) {
		st := recoveryStore(t)
		fetchedAt := time.Date(2026, 9, 20, 13, 25, 0, 0, time.UTC)
		sealedAt := fetchedAt.Add(2 * time.Minute)
		badCard := `{"racecards":[{"race_id":"race-1","course":"Ascot","date":"2026-09-20","off_time":"2:30","off_dt":"2026-09-20T14:30:00+01:00","race_name":"Test Handicap","distance_f":"8.0","region":"GB","race_class":"Class 3","type":"Flat","field_size":"2","going":"Good","surface":"Turf","runners":[{"horse_id":"horse-1","horse":"Runner One","number":"1","draw":"1","age":"5","ofr":"90","lbs":"130","form":"000"},{"horse_id":"horse-2","horse":"Runner Two","number":"2","draw":"2","age":"4","ofr":"80","lbs":"128","form":"111"}]}]}`
		seedLegacyTip(t, st, racecardPayload, badCard, fetchedAt, sealedAt)
		report, err := SealCards(ctx, st, true, sealedAt.Add(time.Hour))
		if err != nil || report.Ambiguous != 1 || report.Recovered != 0 {
			t.Fatalf("mismatching candidate was recovered: %+v, %v", report, err)
		}
	})

	t.Run("not before seal", func(t *testing.T) {
		st := recoveryStore(t)
		sealedAt := time.Date(2026, 9, 20, 13, 27, 0, 0, time.UTC)
		seedLegacyTip(t, st, racecardPayload, racecardPayload, sealedAt, sealedAt)
		report, err := SealCards(ctx, st, true, sealedAt.Add(time.Hour))
		if err != nil || report.Unrecoverable != 1 || report.Recovered != 0 {
			t.Fatalf("payload at seal time was treated as prior: %+v, %v", report, err)
		}
	})
}

func racecardsOffTime(t *testing.T, now time.Time) time.Time {
	t.Helper()
	races, err := racingapi.ParseRacecards([]byte(racecardPayload), now)
	if err != nil || len(races) == 0 || races[0].OffDateTime == nil {
		t.Fatalf("parse test off time: %v", err)
	}
	return races[0].OffDateTime.Time
}
