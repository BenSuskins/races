// Package api is the HTTP surface the app talks to. JSON throughout, with the
// domain objects in the shape the app's own Codable models decode.
//
// Every /v1 route needs `Authorization: Bearer <RACES_API_TOKEN>`. The server
// is reachable only over the LAN and Tailscale; the token is what stops any
// other device on either from reading or writing the record.
package api

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/bensuskins/races/server/internal/backtest"
	"github.com/bensuskins/races/server/internal/betfair"
	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/importer"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/service"
	"github.com/bensuskins/races/server/internal/tracking"
)

// Server is the HTTP API.
type Server struct {
	Service *service.Service
	Token   string
	// Betfair, if configured, for login diagnostics on /v1/status.
	Betfair *betfair.Client
	// RacingConfigured and BetfairConfigured say which providers have
	// credentials; "not configured" is a state, not an error.
	RacingConfigured, BetfairConfigured bool
	Version                             string
	Log                                 *slog.Logger
}

// Handler routes every endpoint.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	s.registerDocumentation(mux)
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /metrics", s.metrics)
	v1 := http.NewServeMux()
	v1.HandleFunc("GET /v1/status", s.status)
	v1.HandleFunc("GET /v1/courses", s.courses)
	v1.HandleFunc("GET /v1/racecards", s.racecards)
	v1.HandleFunc("GET /v1/races/{id}", s.race)
	v1.HandleFunc("GET /v1/tips", s.tips)
	v1.HandleFunc("GET /v1/record", s.record)
	v1.HandleFunc("GET /v1/model", s.model)
	v1.HandleFunc("POST /v1/import", s.importHistory)
	v1.HandleFunc("POST /v1/backtests", s.runBacktest)
	v1.HandleFunc("POST /v1/admin/weights", s.installWeights)
	v1.HandleFunc("GET /v1/backtests", s.backtests)
	v1.HandleFunc("GET /v1/backtests/{id}", s.backtests)
	v1.HandleFunc("POST /v1/admin/jobs/{name}", s.runJob)
	mux.Handle("/v1/", s.authenticated(v1))
	return s.logged(mux)
}

func (s *Server) authenticated(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		const prefix = "Bearer "
		header := r.Header.Get("Authorization")
		if s.Token == "" || !strings.HasPrefix(header, prefix) ||
			subtle.ConstantTimeCompare([]byte(strings.TrimPrefix(header, prefix)), []byte(s.Token)) != 1 {
			writeError(w, http.StatusUnauthorized, "unauthorized", "A valid API token is required.")
			return
		}
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) { r.status = code; r.ResponseWriter.WriteHeader(code) }

func (s *Server) logged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		if r.URL.Path != "/healthz" && r.URL.Path != "/metrics" && s.Log != nil {
			s.Log.Info("request", "method", r.Method, "path", r.URL.Path, "status", rec.status, "ms", time.Since(start).Milliseconds())
		}
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// ErrorBody is every error response.
type ErrorBody struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, ErrorBody{Error: code, Message: message})
}

func (s *Server) internal(w http.ResponseWriter, err error) {
	if s.Log != nil {
		s.Log.Error("handler", "error", err)
	}
	writeError(w, http.StatusInternalServerError, "internal", err.Error())
}

func (s *Server) now() time.Time { return s.Service.Now() }

// MARK: - Health and metrics

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.Service.CheckDatabase(ctx); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": s.Version})
}

func (s *Server) metrics(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	monitoring := s.Service.Monitoring(ctx)
	c := monitoring.Counts
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	gauge := func(name, help string, v int) {
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s gauge\n%s %d\n", name, help, name, name, v)
	}
	gauge("races_races_total", "Races stored.", c.Races)
	gauge("races_results_total", "Results stored.", c.Results)
	gauge("races_tips_total", "Tips recorded.", c.Tips)
	gauge("races_tips_sealed_total", "Tips sealed.", c.SealedTips)
	gauge("races_tips_settled_total", "Tips settled won or lost.", c.SettledTips)
	gauge("races_raw_payloads_total", "Raw provider payloads kept.", c.Payloads)
	gauge("races_training_samples_settled", "Settled training samples.", c.TrainingSettled)
	gauge("races_training_samples_pending", "Training samples awaiting a result.", c.TrainingPending)
	runs := monitoring.Jobs
	fmt.Fprint(w, "# HELP races_job_last_success_timestamp_seconds When each job last succeeded.\n# TYPE races_job_last_success_timestamp_seconds gauge\n")
	for _, j := range runs {
		if j.SucceededAt != nil {
			fmt.Fprintf(w, "races_job_last_success_timestamp_seconds{job=%q} %d\n", j.Name, j.SucceededAt.Unix())
		}
	}
	fmt.Fprint(w, "# HELP races_job_failing Whether a job's last run failed.\n# TYPE races_job_failing gauge\n")
	for _, j := range runs {
		failing := 0
		if j.Error != "" {
			failing = 1
		}
		fmt.Fprintf(w, "races_job_failing{job=%q} %d\n", j.Name, failing)
	}
}

// MARK: - Status

// ProviderStatus is one provider's health, for Settings.
type ProviderStatus struct {
	Configured bool   `json:"configured"`
	Healthy    bool   `json:"healthy"`
	Detail     string `json:"detail,omitempty"`
	// LoginFailure is Betfair's classified login failure, if any.
	LoginFailure *LoginFailureView `json:"loginFailure,omitempty"`
}

// LoginFailureView carries Betfair's own code verbatim.
type LoginFailureView struct {
	Code    string `json:"code"`
	Class   string `json:"class"`
	Message string `json:"message"`
}

// Status is GET /v1/status.
type Status struct {
	Version       string          `json:"version"`
	ServerTime    domain.Instant  `json:"serverTime"`
	ActiveWeights string          `json:"activeWeightsID"`
	RacingAPI     ProviderStatus  `json:"racingAPI"`
	Betfair       ProviderStatus  `json:"betfair"`
	Jobs          []domain.JobRun `json:"jobs"`
	Counts        map[string]int  `json:"counts"`
}

func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	st := Status{Version: s.Version, ServerTime: domain.At(s.now()), Jobs: []domain.JobRun{}}
	monitoring := s.Service.Monitoring(ctx)
	st.ActiveWeights = monitoring.ActiveWeightsID
	runs := monitoring.Jobs
	if runs != nil {
		st.Jobs = runs
	}
	st.RacingAPI = s.providerStatus(runs, s.RacingConfigured, "cards-today", "results")
	st.Betfair = s.providerStatus(runs, s.BetfairConfigured, "markets-today")
	if s.Betfair != nil {
		if f := s.Betfair.Session.LastFailure(); f != nil {
			st.Betfair.Healthy = false
			st.Betfair.LoginFailure = &LoginFailureView{Code: f.Code, Class: f.Class(), Message: f.Message()}
		}
	}
	c := monitoring.Counts
	st.Counts = map[string]int{"races": c.Races, "results": c.Results, "tips": c.Tips, "sealedTips": c.SealedTips,
		"settledTips": c.SettledTips, "rawPayloads": c.Payloads, "trainingSettled": c.TrainingSettled, "trainingPending": c.TrainingPending}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) providerStatus(runs []domain.JobRun, configured bool, jobs ...string) ProviderStatus {
	p := ProviderStatus{Configured: configured, Healthy: configured}
	if !configured {
		p.Detail = "Not configured on the server."
		return p
	}
	for _, j := range runs {
		for _, name := range jobs {
			if j.Name == name && j.Error != "" {
				p.Healthy, p.Detail = false, name+": "+j.Error
			}
		}
	}
	return p
}

// MARK: - Cards

func (s *Server) courses(w http.ResponseWriter, r *http.Request) {
	courses, err := s.Service.Courses(r.Context())
	if err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"courses": courses})
}

// Racecard is GET /v1/racecards.
type Racecard = service.Racecard

func (s *Server) racecards(w http.ResponseWriter, r *http.Request) {
	day, ok := domain.ParseRaceDay(r.URL.Query().Get("day"))
	if !ok {
		day = domain.Today
	}
	card, err := s.Service.Racecard(r.Context(), day)
	if err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, card)
}

// RaceDetail is GET /v1/races/{id}.
type RaceDetail = service.RaceDetail

func (s *Server) race(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	detail, err := s.Service.RaceDetail(r.Context(), id)
	if err != nil {
		s.internal(w, err)
		return
	}
	if detail == nil {
		writeError(w, http.StatusNotFound, "notFound", "No race "+id+".")
		return
	}
	writeJSON(w, http.StatusOK, detail)
}

// MARK: - Record

// TipView is a tip plus where it came from.
type TipView = service.RecordTip

func (s *Server) tips(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	tips, err := s.Service.Tips(r.Context(), q.Get("weightsID"), q.Get("date"))
	if err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"tips": tips})
}

// Record is GET /v1/record.
type Record = service.Record

func (s *Server) record(w http.ResponseWriter, r *http.Request) {
	commission := tracking.DefaultCommission
	if value, err := strconv.ParseFloat(r.URL.Query().Get("commission"), 64); err == nil && value >= 0 && value <= 1 {
		commission = value
	}
	record, err := s.Service.Record(r.Context(), r.URL.Query().Get("weightsID"), commission)
	if err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, record)
}

// MARK: - Model

// Model is GET /v1/model.
type Model = service.Model

func (s *Server) model(w http.ResponseWriter, r *http.Request) {
	model, err := s.Service.Model(r.Context())
	if err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, model)
}

// MARK: - Import

// maxUpload bounds a device upload. A year of tips is a few megabytes.
const maxUpload = 64 << 20

func (s *Server) importHistory(w http.ResponseWriter, r *http.Request) {
	var up importer.Upload
	if err := json.NewDecoder(io.LimitReader(r.Body, maxUpload)).Decode(&up); err != nil {
		writeError(w, http.StatusBadRequest, "badRequest", "Couldn't read the upload: "+err.Error())
		return
	}
	sum, err := s.Service.ImportHistory(r.Context(), up)
	if err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sum)
}

// MARK: - Back-tests

func (s *Server) runBacktest(w http.ResponseWriter, r *http.Request) {
	var request backtest.Request
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "badRequest", err.Error())
		return
	}
	result, err := s.Service.RunBacktest(r.Context(), request)
	var invalid service.InvalidBacktest
	switch {
	case errors.As(err, &invalid):
		writeError(w, http.StatusBadRequest, "badRequest", err.Error())
	case errors.Is(err, service.ErrWeightsNotFound):
		writeError(w, http.StatusNotFound, "notFound", err.Error())
	case err != nil:
		s.internal(w, err)
	default:
		writeJSON(w, http.StatusOK, result)
	}
}

func (s *Server) installWeights(w http.ResponseWriter, r *http.Request) {
	body, readErr := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if readErr != nil {
		writeError(w, http.StatusBadRequest, "badRequest", readErr.Error())
		return
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var weights rating.Weights
	if err := decoder.Decode(&weights); err != nil {
		writeError(w, http.StatusBadRequest, "badRequest", err.Error())
		return
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "badRequest", "The request must contain one JSON object.")
		return
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		s.internal(w, err)
		return
	}
	for _, key := range []string{"marketExponent", "formInfluence", "formInfluenceNoMarket", "clip", "overroundMethod", "minimumMarketCoverage", "factorWeights", "formDecay", "formPoints", "formSeasonBreakPenalty", "formLongBreakPenalty", "formMaxRuns", "minimumStrikeRateSample", "minimumValueEdge", "minimumValueProbability"} {
		if _, exists := fields[key]; !exists {
			writeError(w, http.StatusBadRequest, "badRequest", "The full weight set is required.")
			return
		}
	}
	weights, err := s.Service.InstallWeights(r.Context(), weights)
	var invalid service.InvalidBacktest
	if errors.As(err, &invalid) {
		writeError(w, http.StatusBadRequest, "badRequest", err.Error())
		return
	}
	if err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"weights": weights, "origin": "manual", "active": true})
}

func (s *Server) backtests(w http.ResponseWriter, r *http.Request) {
	var id int64
	if raw := r.PathValue("id"); raw != "" {
		var err error
		if id, err = strconv.ParseInt(raw, 10, 64); err != nil || id <= 0 {
			writeError(w, http.StatusBadRequest, "badRequest", "Bad back-test id.")
			return
		}
	}
	rows, err := s.Service.Backtests(r.Context(), id)
	if err != nil {
		s.internal(w, err)
		return
	}
	if id > 0 {
		if len(rows) == 0 {
			writeError(w, http.StatusNotFound, "notFound", "No such back-test.")
			return
		}
		writeJSON(w, http.StatusOK, rows[0])
		return
	}
	if rows == nil {
		rows = []backtest.StoredReport{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"backtests": rows})
}

// MARK: - Admin

// Jobs that can be triggered by hand.
var jobs = map[string]service.Plan{
	"courses": {Courses: true},
	"cards":   {CardsToday: true, CardsTomorrow: true},
	"markets": {MarketsToday: true, MarketsTomorrow: true},
	"tips":    {DraftToday: true, DraftTomorrow: true, Seal: true},
	"results": {Results: true},
	"train":   {Train: true},
	"all":     service.Everything,
}

func (s *Server) runJob(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	plan, ok := jobs[name]
	if !ok {
		names := make([]string, 0, len(jobs))
		for n := range jobs {
			names = append(names, n)
		}
		sort.Strings(names)
		writeError(w, http.StatusNotFound, "notFound", "Jobs are: "+strings.Join(names, ", ")+".")
		return
	}
	s.Service.Execute(r.Context(), plan)
	runs := s.Service.Monitoring(r.Context()).Jobs
	writeJSON(w, http.StatusOK, map[string]any{"job": name, "jobs": runs})
}
