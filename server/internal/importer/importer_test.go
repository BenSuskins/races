package importer

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/store"
	"github.com/bensuskins/races/server/internal/tracking"
)

var now = time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)

func upload(t *testing.T, device string) Upload {
	t.Helper()
	read := func(n string) []byte {
		b, err := os.ReadFile("testdata/" + n)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	return Upload{Device: device, Tips: read("device-tips.json"), Archive: read("device-archive.json"), Training: read("device-training.json")}
}

func open(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

// The fixtures are hand-written in the exact shape Swift's synthesised
// Codable produces for TipLedger, ResultsArchive and OnDeviceTrainingState.
func TestImportsADevicesHistory(t *testing.T) {
	ctx := context.Background()
	st := open(t)
	sum, err := Import(ctx, st, upload(t, "Ben's iPhone"), now)
	if err != nil {
		t.Fatal(err)
	}
	if len(sum.UnreadableDocuments) != 0 {
		t.Fatal(sum.UnreadableDocuments)
	}
	if sum.TipsAdded != 3 || sum.ArchiveRacesAdded != 2 || sum.SamplesAdded != 1 || sum.PendingAdded != 1 || len(sum.WeightsAdded) != 1 {
		t.Fatalf("%+v", sum)
	}
	row, _ := st.Tip(ctx, "rac_old_1")
	tip := row.Tip
	if row.Source != "device:Ben's iPhone" || tip.Outcome.Kind != tracking.Won || *tip.Outcome.BetfairSP != 2.64 ||
		tip.MarketReference.SelectionIDsByHorseID["hrs_2"] != 10002 || !tip.FavouriteOutcome.Won ||
		tip.Contributions[1].Availability.Kind != rating.NotApplicable || !tip.IsSealed() {
		t.Fatalf("%+v", tip)
	}
	lost, _ := st.Tip(ctx, "rac_old_3")
	if *lost.Tip.Outcome.Position != 4 || lost.Tip.WeightsID != "learned-1757689000-520" {
		t.Fatal("lost with position, and the weights id it was made under")
	}

	// The report over imported tips is the report the phone showed.
	rows, _ := st.Tips(ctx, "", "")
	var tips []tracking.Tip
	for _, r := range rows {
		tips = append(tips, r.Tip)
	}
	rep := tracking.Accuracy(tips, tracking.DefaultCommission)
	if rep.Settled != 2 || rep.Wins != 1 || rep.Expired != 1 || rep.FavouriteBaseline.Settled != 1 {
		t.Fatalf("%+v", rep)
	}
	if w, _ := st.Weights(ctx, "learned-1757689000-520"); w == nil || w.MarketExponent != 1.02 {
		t.Fatal("the phone's promoted weights are kept")
	}
	if active, _ := st.ActiveWeights(ctx); active != nil {
		t.Fatal("but not activated")
	}
	if settled, pending := st.TrainingCounts(ctx); settled != 1 || pending != 1 {
		t.Fatal(settled, pending)
	}
}

func TestAReUploadChangesNothing(t *testing.T) {
	ctx := context.Background()
	st := open(t)
	Import(ctx, st, upload(t, "phone"), now)
	sum, err := Import(ctx, st, upload(t, "phone"), now)
	if err != nil {
		t.Fatal(err)
	}
	if sum.TipsAdded != 0 || sum.TipsReplaced != 0 || sum.TipsKept != 3 || sum.ArchiveRacesAdded != 0 || sum.SamplesAdded != 0 || sum.PendingAdded != 0 || len(sum.WeightsAdded) != 0 {
		t.Fatalf("%+v", sum)
	}
}

func TestServerTipsAlwaysWin(t *testing.T) {
	ctx := context.Background()
	st := open(t)
	server := tracking.Tip{RaceID: "rac_old_1", RaceDate: "2026-09-10", SelectionHorseID: "hrs_2", WeightsID: "v2",
		SealedAt: domain.Ptr(time.Date(2026, 9, 10, 13, 29, 0, 0, time.UTC)), CreatedAt: domain.At(now), Contributions: []rating.Contribution{}}
	st.SaveTip(ctx, server, "server", now)
	sum, _ := Import(ctx, st, upload(t, "phone"), now)
	if sum.TipsKept != 1 {
		t.Fatalf("%+v", sum)
	}
	row, _ := st.Tip(ctx, "rac_old_1")
	if row.Source != "server" || row.Tip.SelectionHorseID != "hrs_2" {
		t.Fatal("a server-sealed tip is never replaced by an upload")
	}
}

func TestUnreadableDocumentsAreReportedNotFatal(t *testing.T) {
	st := open(t)
	up := upload(t, "phone")
	up.Archive = []byte(`{"schemaVersion":2,"payload":{}}`)
	sum, err := Import(context.Background(), st, up, now)
	if err != nil || len(sum.UnreadableDocuments) != 1 || sum.TipsAdded != 3 {
		t.Fatalf("%+v %v", sum, err)
	}
}
