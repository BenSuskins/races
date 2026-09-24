package betfair

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/bensuskins/races/server/internal/httpx"
)

func fixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// fake is a scripted exchange: login replies and per-path queues.
type fake struct {
	mu       sync.Mutex
	logins   []string
	replies  map[string][]string
	calls    map[string]int
	bodies   map[string][]string
	headers  []http.Header
	loginRaw string
}

func newFake() *fake {
	return &fake{replies: map[string][]string{}, calls: map[string]int{}, bodies: map[string][]string{}}
}

func (f *fake) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	body, _ := io.ReadAll(r.Body)
	f.calls[r.URL.Path]++
	f.bodies[r.URL.Path] = append(f.bodies[r.URL.Path], string(body))
	f.headers = append(f.headers, r.Header.Clone())
	if r.URL.Path == "/api/login" {
		f.loginRaw = string(body)
		reply := `{"token":"TOKEN","status":"SUCCESS"}`
		if len(f.logins) > 0 {
			reply, f.logins = f.logins[0], f.logins[1:]
		}
		if strings.HasPrefix(reply, "<") {
			w.Header().Set("Content-Type", "text/html")
		}
		w.Write([]byte(reply))
		return
	}
	q := f.replies[r.URL.Path]
	if len(q) == 0 {
		w.Write([]byte(`[]`))
		return
	}
	reply := q[0]
	if len(q) > 1 {
		f.replies[r.URL.Path] = q[1:]
	}
	w.Write([]byte(reply))
}

func client(t *testing.T, f *fake, creds Credentials) *Client {
	t.Helper()
	s := httptest.NewServer(f)
	t.Cleanup(s.Close)
	h := httpx.New(s.URL, 0, nil)
	h.Retry = httpx.NoRetry
	return New(creds, h, h, func() time.Time { return time.Date(2026, 9, 22, 10, 0, 0, 0, time.UTC) })
}

var creds = Credentials{AppKey: "KEY", Username: "me", Password: "pa+ss"}

func TestMarketsMapAndFilter(t *testing.T) {
	f := newFake()
	f.replies["/listMarketCatalogue/"] = []string{fixture(t, "betfair-listmarketcatalogue.json")}
	c := client(t, f, creds)
	markets, err := c.Markets(context.Background(), "2026-09-22")
	if err != nil {
		t.Fatal(err)
	}
	if len(markets) != 2 {
		t.Fatal("a market with no start time is refused, not matched on venue alone")
	}
	ascot := markets[0]
	if ascot.Venue != "Ascot" || ascot.Runners[0].Name != "1. Kyprios (IRE)" || *ascot.Runners[0].ClothNumber != 1 {
		t.Fatalf("%+v", ascot)
	}
	if ascot.Runners[2].IsActive || ascot.Runners[3].ClothNumber != nil {
		t.Fatal("removed runner inactive; cloth 0 is absent")
	}
	var req map[string]any
	json.Unmarshal([]byte(f.bodies["/listMarketCatalogue/"][0]), &req)
	filter := req["filter"].(map[string]any)
	window := filter["marketStartTime"].(map[string]any)
	// 22 Sep is BST, so the London day starts at 23:00 UTC the evening before.
	if window["from"] != "2026-09-21T23:00:00Z" || window["to"] != "2026-09-22T23:00:00Z" || filter["marketTypeCodes"].([]any)[0] != "WIN" {
		t.Fatalf("%v", filter)
	}
	last := f.headers[len(f.headers)-1]
	if last.Get("X-Application") != "KEY" || last.Get("X-Authentication") != "TOKEN" {
		t.Fatal("both headers on a betting call")
	}
	if !strings.Contains(f.loginRaw, "password=pa%2Bss") {
		t.Fatal("a + in the password must survive form encoding:", f.loginRaw)
	}
}

func TestPricesAreBestFirst(t *testing.T) {
	f := newFake()
	f.replies["/listMarketBook/"] = []string{fixture(t, "betfair-listmarketbook.json")}
	c := client(t, f, creds)
	prices, err := c.Prices(context.Background(), []string{"1.245678901"})
	if err != nil {
		t.Fatal(err)
	}
	p := prices[0].Prices[12345678]
	if *p.BackPrice != 2.4 || *p.LayPrice != 2.46 || *p.LastTraded != 2.42 || *p.ForecastPrice != 2.44 || !prices[0].IsDelayed {
		t.Fatalf("%+v", p)
	}
	if prices[0].Prices[32345678].IsActive {
		t.Fatal("removed runner inactive")
	}
}

func TestBatchingAndDedup(t *testing.T) {
	f := newFake()
	c := client(t, f, creds)
	var ids []string
	for i := range 85 {
		ids = append(ids, "1."+string(rune('a'+i%26))+strings.Repeat("x", i/26))
	}
	ids = append(ids, ids[0])
	c.Prices(context.Background(), ids)
	if f.calls["/listMarketBook/"] != 3 {
		t.Fatal("85 unique markets is three batches of at most 40:", f.calls["/listMarketBook/"])
	}
	f.calls = map[string]int{}
	c.Prices(context.Background(), nil)
	if f.calls["/listMarketBook/"] != 0 {
		t.Fatal("no ids, no request")
	}
}

func TestTooMuchDataSplits(t *testing.T) {
	f := newFake()
	f.replies["/listMarketBook/"] = []string{fixture(t, "betfair-apingexception-toomuchdata.json"), `[{"marketId":"1.1","runners":[{"selectionId":1}]}]`}
	c := client(t, f, creds)
	prices, err := c.Prices(context.Background(), []string{"1.1", "1.2"})
	if err != nil || len(prices) != 2 || f.calls["/listMarketBook/"] != 3 {
		t.Fatal(err, len(prices), f.calls)
	}
}

func TestExpiredSessionRetriedOnce(t *testing.T) {
	f := newFake()
	fault := fixture(t, "betfair-apingexception-session.json")
	f.replies["/listMarketCatalogue/"] = []string{fault, `[]`}
	c := client(t, f, creds)
	if _, err := c.Markets(context.Background(), "2026-09-22"); err != nil || f.calls["/api/login"] != 2 {
		t.Fatal("re-authenticate once and retry", err, f.calls)
	}
	f.replies["/listMarketCatalogue/"] = []string{fault, fault}
	f.calls = map[string]int{}
	_, err := c.Markets(context.Background(), "2026-09-22")
	if httpx.KindOf(err) != httpx.Unauthorized || f.calls["/listMarketCatalogue/"] != 2 {
		t.Fatal("a second failure is surfaced, not looped", err, f.calls)
	}
}

// Betfair sends faults on a 200. Mapping only status codes would let one
// through as an empty list, which looks exactly like "no racing today".
func TestFaultOnA200IsNotAnEmptyResult(t *testing.T) {
	f := newFake()
	f.replies["/listMarketCatalogue/"] = []string{`{"faultcode":"Client","faultstring":"ANGX-0001","detail":{"APINGException":{"errorCode":"SOMETHING_NEW"}}}`}
	_, err := client(t, f, creds).Markets(context.Background(), "2026-09-22")
	if err == nil || !strings.Contains(err.Error(), "SOMETHING_NEW") {
		t.Fatal("the unknown code must be carried through:", err)
	}
}

func TestStartingPrices(t *testing.T) {
	f := newFake()
	f.replies["/listMarketBook/"] = []string{fixture(t, "betfair-listmarketbook-settled.json")}
	c := client(t, f, creds)
	sps, err := c.StartingPrices(context.Background(), []string{"1.245678901"})
	if err != nil {
		t.Fatal(err)
	}
	m := sps["1.245678901"]
	if m[12345678] != 2.64 || m[22345678] != 5.2 || len(m) != 2 {
		t.Fatal("absent or zero SPs are omitted, not defaulted", m)
	}
	if !strings.Contains(f.bodies["/listMarketBook/"][0], "SP_TRADED") {
		t.Fatal("asks for SP_TRADED")
	}
}

func TestLoginClassification(t *testing.T) {
	cases := map[string]string{
		"betfair-login-2fa.json":          "userActionRequired",
		"betfair-login-certrequired.json": "certificateRequired",
	}
	for file, class := range cases {
		f := newFake()
		f.logins = []string{fixture(t, file)}
		c := client(t, f, creds)
		_, err := c.Session.Token(context.Background())
		lf, ok := AsLoginFailure(err)
		if !ok || lf.Class() != class {
			t.Fatalf("%s: %v", file, err)
		}
		c.Session.Token(context.Background())
		if f.calls["/api/login"] != 1 {
			t.Fatal("a permanent failure is latched, not retried every call")
		}
	}
	f := newFake()
	f.logins = []string{`{"status":"FAIL","error":"INVALID_USERNAME_OR_PASSWORD"}`, `{"token":"T","status":"SUCCESS"}`}
	c := client(t, f, creds)
	if _, err := c.Session.Token(context.Background()); err == nil {
		t.Fatal("bad credentials")
	}
	if tok, err := c.Session.Token(context.Background()); err != nil || tok != "T" {
		t.Fatal("bad credentials are retryable")
	}
	f = newFake()
	f.logins = []string{`{"status":"FAIL"}`}
	if _, err := client(t, f, creds).Session.Token(context.Background()); err.(*LoginFailure).Code != "FAIL" {
		t.Fatal("a FAIL with no error still has a code")
	}
}

func TestUnreadableLoginReplyIsReportedAndNotLatched(t *testing.T) {
	f := newFake()
	f.logins = []string{"<!DOCTYPE html><html>Not available in your region</html>", `{"token":"T","status":"SUCCESS"}`}
	c := client(t, f, creds)
	_, err := c.Session.Token(context.Background())
	lf, ok := AsLoginFailure(err)
	if !ok || lf.Code != UnreadableResponse || !strings.Contains(lf.Message(), "never checked") || !strings.Contains(lf.Detail, "text/html") {
		t.Fatal(err)
	}
	if tok, _ := c.Session.Token(context.Background()); tok != "T" {
		t.Fatal("an unreadable reply is not latched")
	}
	f = newFake()
	f.logins = []string{`{"unexpected":"shape"}`}
	if _, err := client(t, f, creds).Session.Token(context.Background()); err.(*LoginFailure).Code == UnreadableResponse {
		t.Fatal("valid JSON of the wrong shape is not unreadable")
	}
}

func TestIncompleteCredentialsNeverReachTheNetwork(t *testing.T) {
	f := newFake()
	_, err := client(t, f, Credentials{AppKey: "K", Username: "u"}).Session.Token(context.Background())
	if httpx.KindOf(err) != httpx.NotConfigured || f.calls["/api/login"] != 0 {
		t.Fatal(err)
	}
}

func TestClothNumberMetadata(t *testing.T) {
	s := func(v string) *string { return &v }
	cases := map[*string]bool{s("4"): true, s("0"): false, s(" "): false, s("x"): false, nil: false}
	for v, want := range cases {
		if got := ClothNumber(map[string]*string{"CLOTH_NUMBER": v}) != nil; got != want {
			t.Fatal(v)
		}
	}
	var m metadata
	if err := json.Unmarshal([]byte(`{"CLOTH_NUMBER":5,"FORM":null,"X":true}`), &m); err != nil || *ClothNumber(m) != 5 {
		t.Fatal("numeric metadata", err)
	}
}
