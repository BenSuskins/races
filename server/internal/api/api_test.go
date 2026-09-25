package api

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/backtest"
	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/importer"
	"github.com/bensuskins/races/server/internal/racingapi"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/service"
	"github.com/bensuskins/races/server/internal/store"
	"github.com/bensuskins/races/server/internal/testutil"
	"github.com/bensuskins/races/server/internal/tracking"
)

const token = "test-token-0123456789"

// fixtureRacing replays the committed Racing API fixtures.
type fixtureRacing struct{ t *testing.T }

func (f fixtureRacing) read(name string) []byte {
	b, err := os.ReadFile("../racingapi/testdata/" + name)
	if err != nil {
		f.t.Fatal(err)
	}
	return b
}

func (f fixtureRacing) Courses(ctx context.Context, regions ...string) ([]domain.Course, error) {
	return []domain.Course{{ID: "crs_1", Name: "Ascot", RegionCode: "gb", Region: "Great Britain"}}, nil
}
func (f fixtureRacing) Racecards(ctx context.Context, day domain.RaceDay, regions ...string) ([]domain.Race, error) {
	if day == domain.Tomorrow {
		return nil, nil
	}
	return racingapi.ParseRacecards(f.read("racingapi-racecards-free.json"), now)
}
func (f fixtureRacing) TodaysResults(ctx context.Context) ([]domain.RaceResult, error) {
	return racingapi.ParseResults(f.read("racingapi-results-today-free.json"), now)
}

var now = time.Date(2026, 9, 20, 9, 0, 0, 0, time.UTC)

func setup(t *testing.T) (*httptest.Server, *service.Service) {
	t.Helper()
	st, err := store.Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	svc := service.New(st, fixtureRacing{t}, nil, func() time.Time { return now }, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := svc.Bootstrap(context.Background()); err != nil {
		t.Fatal(err)
	}
	s := httptest.NewServer((&Server{Service: svc, Token: token, RacingConfigured: true, Version: "test"}).Handler())
	t.Cleanup(s.Close)
	return s, svc
}

func call(t *testing.T, s *httptest.Server, method, path string, body any, auth bool) (int, []byte) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, s.URL+path, reader)
	if auth {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	return res.StatusCode, data
}

func TestEveryV1RouteNeedsTheToken(t *testing.T) {
	s, _ := setup(t)
	for _, path := range []string{"/v1/status", "/v1/racecards", "/v1/record", "/v1/model", "/v1/tips"} {
		if code, _ := call(t, s, "GET", path, nil, false); code != 401 {
			t.Fatalf("%s without a token: %d", path, code)
		}
	}
	req, _ := http.NewRequest("GET", s.URL+"/v1/status", nil)
	req.Header.Set("Authorization", "Bearer wrong")
	if res, _ := http.DefaultClient.Do(req); res.StatusCode != 401 {
		t.Fatal("a wrong token")
	}
	if code, _ := call(t, s, "GET", "/healthz", nil, false); code != 200 {
		t.Fatal("healthz is open, for Gatus")
	}
	if code, body := call(t, s, "GET", "/metrics", nil, false); code != 200 || !strings.Contains(string(body), "races_tips_total") {
		t.Fatal("metrics")
	}
}

func TestRacecardAndRaceDetail(t *testing.T) {
	s, svc := setup(t)
	svc.Execute(context.Background(), service.Everything)
	code, body := call(t, s, "GET", "/v1/racecards?day=today", nil, true)
	if code != 200 {
		t.Fatal(code, string(body))
	}
	var card Racecard
	if err := json.Unmarshal(body, &card); err != nil {
		t.Fatal(err)
	}
	if card.Date != "2026-09-20" || len(card.Races) != 2 || len(card.Assessments) != 2 || len(card.Tips) != 2 {
		t.Fatalf("%+v", card)
	}
	// Dates go out as whole-second UTC, which Swift's .iso8601 decoder needs.
	if !strings.Contains(string(body), `"offDateTime":"2026-09-20T13:30:00Z"`) {
		t.Fatal("instant format")
	}
	code, body = call(t, s, "GET", "/v1/races/rac_1001", nil, true)
	var d RaceDetail
	json.Unmarshal(body, &d)
	if code != 200 || d.Assessment == nil || d.Tip == nil || d.Result == nil {
		t.Fatalf("%d %s", code, body)
	}
	if code, _ := call(t, s, "GET", "/v1/races/nope", nil, true); code != 404 {
		t.Fatal("unknown race")
	}
}

func TestImportRecordAndModel(t *testing.T) {
	s, _ := setup(t)
	read := func(n string) json.RawMessage {
		b, _ := os.ReadFile("../importer/testdata/" + n)
		return b
	}
	up := importer.Upload{Device: "phone", Tips: read("device-tips.json"), Archive: read("device-archive.json"), Training: read("device-training.json")}
	code, body := call(t, s, "POST", "/v1/import", up, true)
	var sum importer.Summary
	json.Unmarshal(body, &sum)
	if code != 200 || sum.TipsAdded != 3 {
		t.Fatal(code, string(body))
	}
	_, body = call(t, s, "POST", "/v1/import", up, true)
	json.Unmarshal(body, &sum)
	if sum.TipsAdded != 0 || sum.TipsKept != 3 {
		t.Fatal("a second upload adds nothing", string(body))
	}
	code, body = call(t, s, "GET", "/v1/record", nil, true)
	var rec Record
	json.Unmarshal(body, &rec)
	if code != 200 || rec.WeightsID != "v3" || rec.ActiveWeightsID != "v3" || rec.Report.Total != 0 {
		t.Fatalf("the default record uses the active population: %s", string(body))
	}
	_, body = call(t, s, "GET", "/v1/record?weightsID=v2", nil, true)
	json.Unmarshal(body, &rec)
	if rec.Report.Settled != 1 || rec.Sources["device:phone"] != 2 || rec.Report.BenchmarkedModel.Settled != 1 || len(rec.RecentTips) != 2 {
		t.Fatalf("the record splits by weight id: %s", string(body))
	}
	hasFrozenContributions := false
	for _, tip := range rec.RecentTips {
		if tip.WeightsID != "v2" || tip.RaceID == "" {
			t.Fatalf("recent details must use the selected weight set: %+v", tip)
		}
		hasFrozenContributions = hasFrozenContributions || len(tip.Contributions) > 0
	}
	if !hasFrozenContributions {
		t.Fatalf("recent record details must keep the frozen tip and rating: %s", string(body))
	}
	code, body = call(t, s, "GET", "/v1/model", nil, true)
	var m Model
	json.Unmarshal(body, &m)
	if code != 200 || m.Active.ID != "v3" || len(m.Factors) != 21 || len(m.Weights) != 5 {
		t.Fatal(string(body))
	}
}

func TestBacktestAndJobs(t *testing.T) {
	s, _ := setup(t)
	if code, body := call(t, s, "POST", "/v1/admin/jobs/all", nil, true); code != 200 {
		t.Fatal(string(body))
	}
	code, body := call(t, s, "POST", "/v1/backtests", map[string]string{"weightsID": "market-only"}, true)
	if code != 200 || !strings.Contains(string(body), `"weightsID":"market-only"`) {
		t.Fatal(code, string(body))
	}
	if code, _ := call(t, s, "GET", "/v1/backtests/1", nil, true); code != 200 {
		t.Fatal("stored")
	}
	if code, _ := call(t, s, "POST", "/v1/backtests", map[string]string{"weightsID": "nope"}, true); code != 404 {
		t.Fatal("unknown weights")
	}
	if code, _ := call(t, s, "POST", "/v1/admin/jobs/nope", nil, true); code != 404 {
		t.Fatal("unknown job")
	}
	code, body = call(t, s, "GET", "/v1/status", nil, true)
	var st Status
	json.Unmarshal(body, &st)
	if code != 200 || !st.RacingAPI.Configured || st.Betfair.Configured || st.ActiveWeights != "v3" || len(st.Jobs) == 0 {
		t.Fatal(string(body))
	}
}

func TestManualWeightsAreValidatedAndActivatedAtomically(t *testing.T) {
	s, svc := setup(t)
	old := tracking.Tip{RaceID: "old-race", WeightsID: "v3"}
	if err := svc.Store.SaveTip(context.Background(), old, "server", time.Now()); err != nil {
		t.Fatal(err)
	}
	code, body := call(t, s, "POST", "/v1/admin/weights", rating.V2(), true)
	if code != http.StatusCreated {
		t.Fatalf("%d: %s", code, body)
	}
	var result struct {
		Weights rating.Weights `json:"weights"`
		Origin  string         `json:"origin"`
		Active  bool           `json:"active"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	active, err := svc.Store.ActiveWeights(context.Background())
	if err != nil || active.ID != result.Weights.ID || !strings.HasPrefix(active.ID, "manual-") || result.Origin != "manual" || !result.Active {
		t.Fatalf("manual weights were not activated: %+v, %+v, %v", result, active, err)
	}
	unchanged, err := svc.Store.Tip(context.Background(), "old-race")
	if err != nil || unchanged == nil || unchanged.Tip.WeightsID != "v3" {
		t.Fatal("manual promotion changed a sealed tip", err)
	}
	code, body = call(t, s, "POST", "/v1/admin/weights", map[string]any{"id": "incomplete"}, true)
	if code != http.StatusBadRequest {
		t.Fatalf("incomplete body accepted: %d %s", code, body)
	}
	after, err := svc.Store.ActiveWeights(context.Background())
	if err != nil || after.ID != active.ID {
		t.Fatal("invalid body changed the active set", err)
	}
}

func TestBacktestSweepUsesOneCorpusAndRejectsUnknownOverrides(t *testing.T) {
	s, _ := setup(t)
	request := map[string]any{
		"weightsID": "v3",
		"variants": []any{
			map[string]any{"name": "decay-low", "overrides": map[string]any{"formDecay": 0.4}},
			map[string]any{"name": "power", "overrides": map[string]any{"overroundMethod": "power"}},
		},
	}
	code, body := call(t, s, "POST", "/v1/backtests", request, true)
	var result struct {
		Sweep backtest.SweepReport `json:"sweep"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	if code != http.StatusOK || len(result.Sweep.Reports) != 2 || result.Sweep.SharedCorpusID == "" ||
		result.Sweep.Reports[0].Report.CorpusID != result.Sweep.SharedCorpusID || result.Sweep.Reports[1].Report.CorpusID != result.Sweep.SharedCorpusID {
		t.Fatalf("variants did not share a corpus: %d %s", code, body)
	}
	request["variants"] = []any{map[string]any{"name": "bad", "overrides": map[string]any{"unknownField": 1}}}
	code, body = call(t, s, "POST", "/v1/backtests", request, true)
	if code != http.StatusBadRequest {
		t.Fatalf("unknown override accepted: %d %s", code, body)
	}
}

var update = flag.Bool("update", false, "rewrite the app's contract fixtures")

// The app decodes these responses with its own Codable models, and
// RacesKit's ServerContractTests decodes these exact files. Regenerate with
// `go test ./internal/api -update` whenever a response shape changes, and run
// the kit's tests before merging.
func TestContractFixtures(t *testing.T) {
	s, svc := setup(t)
	read := func(n string) json.RawMessage {
		b, _ := os.ReadFile("../importer/testdata/" + n)
		return b
	}
	up := importer.Upload{Device: "phone", Tips: read("device-tips.json"), Archive: read("device-archive.json"), Training: read("device-training.json")}
	_, importBody := call(t, s, "POST", "/v1/import", up, true)
	svc.Execute(context.Background(), service.Everything)

	responses := map[string][]byte{"server-import.json": importBody}
	for name, path := range map[string]string{
		"server-racecard.json": "/v1/racecards?day=today",
		"server-race.json":     "/v1/races/rac_1001",
		"server-record.json":   "/v1/record",
		"server-model.json":    "/v1/model",
		"server-status.json":   "/v1/status",
		"server-courses.json":  "/v1/courses",
	} {
		code, body := call(t, s, "GET", path, nil, true)
		if code != 200 {
			t.Fatalf("%s: %d %s", path, code, body)
		}
		responses[name] = body
	}
	dir := "../../../ios/RacesKit/Tests/RacesKitTests/Fixtures/"
	for name, body := range responses {
		var pretty bytes.Buffer
		if err := json.Indent(&pretty, body, "", "  "); err != nil {
			t.Fatal(name, err)
		}
		if *update {
			if err := os.WriteFile(dir+name, pretty.Bytes(), 0o644); err != nil {
				t.Fatal(err)
			}
			continue
		}
		existing, err := os.ReadFile(dir + name)
		matches, compareErr := testutil.CompareJSON(existing, pretty.Bytes())
		if err != nil || compareErr != nil || !matches {
			t.Fatalf("%s no longer matches the committed contract fixture; regenerate with -update and run RacesKit's ServerContractTests", name)
		}
	}
}
