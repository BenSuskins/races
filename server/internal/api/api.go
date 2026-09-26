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
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
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
	"github.com/bensuskins/races/server/internal/store"
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
	if _, err := s.Service.Store.ActiveWeights(ctx); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": s.Version})
}

func (s *Server) metrics(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	c := s.Service.Store.Counts(ctx)
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
	runs, _ := s.Service.Store.JobRuns(ctx)
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
	Version       string         `json:"version"`
	ServerTime    domain.Instant `json:"serverTime"`
	ActiveWeights string         `json:"activeWeightsID"`
	RacingAPI     ProviderStatus `json:"racingAPI"`
	Betfair       ProviderStatus `json:"betfair"`
	Jobs          []store.JobRun `json:"jobs"`
	Counts        map[string]int `json:"counts"`
}

func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	st := Status{Version: s.Version, ServerTime: domain.At(s.now()), Jobs: []store.JobRun{}}
	if a, _ := s.Service.Store.ActiveWeights(ctx); a != nil {
		st.ActiveWeights = a.ID
	}
	runs, _ := s.Service.Store.JobRuns(ctx)
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
	c := s.Service.Store.Counts(ctx)
	st.Counts = map[string]int{"races": c.Races, "results": c.Results, "tips": c.Tips, "sealedTips": c.SealedTips,
		"settledTips": c.SettledTips, "rawPayloads": c.Payloads, "trainingSettled": c.TrainingSettled, "trainingPending": c.TrainingPending}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) providerStatus(runs []store.JobRun, configured bool, jobs ...string) ProviderStatus {
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
	courses, err := s.Service.Store.Courses(r.Context())
	if err != nil {
		s.internal(w, err)
		return
	}
	if courses == nil {
		courses = []domain.Course{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"courses": courses})
}

// Racecard is GET /v1/racecards: one day's card with everything the Racing and
// Tips tabs show, keyed by race id.
type Racecard struct {
	Day         domain.RaceDay               `json:"day"`
	Date        string                       `json:"date"`
	FetchedAt   *domain.Instant              `json:"fetchedAt,omitempty"`
	Races       []domain.Race                `json:"races"`
	Assessments map[string]rating.Assessment `json:"assessments"`
	Tips        map[string]tracking.Tip      `json:"tips"`
	Results     map[string]domain.RaceResult `json:"results"`
	Refusals    map[string]json.RawMessage   `json:"refusals"`
	// ArchivedRaces is how many results feed the strike-rate factors.
	ArchivedRaces int `json:"archivedRaces"`
}

func (s *Server) racecards(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	day, ok := domain.ParseRaceDay(r.URL.Query().Get("day"))
	if !ok {
		day = domain.Today
	}
	date := domain.DayStringFor(day, s.now())
	card := Racecard{Day: day, Date: date, Races: []domain.Race{}, Tips: map[string]tracking.Tip{},
		Results: map[string]domain.RaceResult{}, Refusals: map[string]json.RawMessage{}}
	var err error
	if card.Races, err = s.Service.Store.RacesOn(ctx, date); err != nil {
		s.internal(w, err)
		return
	}
	if card.Races == nil {
		card.Races = []domain.Race{}
	}
	if at, ok := s.Service.Store.RacecardsFetchedAt(ctx, date); ok {
		card.FetchedAt = domain.Ptr(at)
	}
	if card.Assessments, err = s.Service.Store.AssessmentsOn(ctx, date); err != nil {
		s.internal(w, err)
		return
	}
	tips, _ := s.Service.Store.Tips(ctx, "", date)
	for _, t := range tips {
		card.Tips[t.Tip.RaceID] = t.Tip
	}
	results, _ := s.Service.Store.ResultsOn(ctx, date)
	for _, res := range results {
		card.Results[res.ID] = res
	}
	ids := make([]string, len(card.Races))
	for i, race := range card.Races {
		ids[i] = race.ID
	}
	matches, _ := s.Service.Store.Matches(ctx, ids)
	for id, m := range matches {
		if len(m.Refusal) > 0 {
			card.Refusals[id] = m.Refusal
		}
	}
	card.ArchivedRaces = s.Service.ArchivedRaceCount(ctx)
	writeJSON(w, http.StatusOK, card)
}

// RaceDetail is GET /v1/races/{id}.
type RaceDetail struct {
	Race       domain.Race            `json:"race"`
	Assessment *rating.Assessment     `json:"assessment,omitempty"`
	Tip        *tracking.Tip          `json:"tip,omitempty"`
	Result     *domain.RaceResult     `json:"result,omitempty"`
	Snapshot   *domain.MarketSnapshot `json:"snapshot,omitempty"`
	Refusal    json.RawMessage        `json:"refusal,omitempty"`
}

func (s *Server) race(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")
	race, err := s.Service.Store.Race(ctx, id)
	if err != nil {
		s.internal(w, err)
		return
	}
	if race == nil {
		writeError(w, http.StatusNotFound, "notFound", "No race "+id+".")
		return
	}
	d := RaceDetail{Race: *race}
	d.Assessment, _ = s.Service.Store.Assessment(ctx, id)
	if row, _ := s.Service.Store.Tip(ctx, id); row != nil {
		d.Tip = &row.Tip
	}
	d.Result, _ = s.Service.Store.Result(ctx, id)
	if d.Tip != nil && d.Tip.IsSealed() {
		d.Snapshot, _ = s.Service.Store.LatestSnapshot(ctx, id, "seal")
	}
	if d.Snapshot == nil {
		d.Snapshot, _ = s.Service.Store.LatestSnapshot(ctx, id, "display")
	}
	if m, _ := s.Service.Store.Matches(ctx, []string{id}); len(m[id].Refusal) > 0 {
		d.Refusal = m[id].Refusal
	}
	writeJSON(w, http.StatusOK, d)
}

// MARK: - Record

// TipView is a tip plus where it came from.
type TipView struct {
	tracking.Tip
	Source string `json:"source"`
}

func (s *Server) tips(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	rows, err := s.Service.Store.Tips(r.Context(), q.Get("weightsID"), q.Get("date"))
	if err != nil {
		s.internal(w, err)
		return
	}
	out := make([]TipView, len(rows))
	for i, row := range rows {
		out[i] = TipView{Tip: row.Tip, Source: row.Source}
	}
	writeJSON(w, http.StatusOK, map[string]any{"tips": out})
}

// Record is GET /v1/record.
type Record struct {
	WeightsID       string          `json:"weightsID,omitempty"`
	ActiveWeightsID string          `json:"activeWeightsID,omitempty"`
	Commission      float64         `json:"commission"`
	Report          tracking.Report `json:"report"`
	RecentTips      []TipView       `json:"recentTips"`
	WeightsInUse    map[string]int  `json:"weightsInUse"`
	// Sources counts tips by where they came from, so a record that is mostly
	// imported history says so.
	Sources       map[string]int `json:"sources"`
	ArchivedRaces int            `json:"archivedRaces"`
}

const recordTipDetailLimit = 30

func (s *Server) record(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	weightsID := r.URL.Query().Get("weightsID")
	active, err := s.Service.Store.ActiveWeights(ctx)
	if err != nil {
		s.internal(w, err)
		return
	}
	if weightsID == "" && active != nil {
		weightsID = active.ID
	}
	commission := tracking.DefaultCommission
	if c, err := strconv.ParseFloat(r.URL.Query().Get("commission"), 64); err == nil && c >= 0 && c <= 1 {
		commission = c
	}
	rows, err := s.Service.Store.Tips(ctx, weightsID, "")
	if err != nil {
		s.internal(w, err)
		return
	}
	tips := make([]tracking.Tip, len(rows))
	sources := map[string]int{}
	for i, row := range rows {
		tips[i] = row.Tip
		sources[row.Source]++
	}
	recentTips := make([]TipView, 0, min(len(rows), recordTipDetailLimit))
	for _, row := range rows {
		if row.Tip.Outcome == nil || !row.Tip.Outcome.IsSettled() {
			continue
		}
		recentTips = append(recentTips, TipView{Tip: row.Tip, Source: row.Source})
		if len(recentTips) == recordTipDetailLimit {
			break
		}
	}
	inUse, _ := s.Service.Store.WeightsIDsInUse(ctx)
	activeID := ""
	if active != nil {
		activeID = active.ID
	}
	writeJSON(w, http.StatusOK, Record{WeightsID: weightsID, ActiveWeightsID: activeID, Commission: commission, Report: tracking.Accuracy(tips, commission), RecentTips: recentTips, WeightsInUse: inUse, Sources: sources, ArchivedRaces: s.Service.ArchivedRaceCount(ctx)})
}

// MARK: - Model

// FactorView is a factor with the copy that explains it.
type FactorView struct {
	ID        rating.FactorID `json:"id"`
	Label     string          `json:"label"`
	Summary   string          `json:"summary"`
	Rationale string          `json:"rationale,omitempty"`
}

// Model is GET /v1/model: read-only, as the Model tab has always been.
type Model struct {
	ModelVersion  string             `json:"modelVersion"`
	Active        rating.Weights     `json:"active"`
	Weights       []store.WeightsRow `json:"weights"`
	Factors       []FactorView       `json:"factors"`
	Training      any                `json:"training,omitempty"`
	Samples       map[string]int     `json:"samples"`
	ArchivedRaces int                `json:"archivedRaces"`
}

func (s *Server) model(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	active, err := s.Service.Store.ActiveWeights(ctx)
	if err != nil || active == nil {
		s.internal(w, errors.Join(err, errors.New("no active weights")))
		return
	}
	all, _ := s.Service.Store.AllWeights(ctx)
	m := Model{ModelVersion: rating.ModelVersion, Active: *active, Weights: all}
	for _, id := range rating.AllFactors {
		m.Factors = append(m.Factors, FactorView{ID: id, Label: id.Label(), Summary: id.Summary(), Rationale: id.Rationale()})
	}
	if rep := s.Service.LastTrainingReport(ctx); rep != nil {
		m.Training = rep
	}
	settled, pending := s.Service.Store.TrainingCounts(ctx)
	m.Samples = map[string]int{"settled": settled, "pending": pending, "minimumRaces": s.Service.Training.MinimumRaces}
	m.ArchivedRaces = s.Service.ArchivedRaceCount(ctx)
	writeJSON(w, http.StatusOK, m)
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
	sum, err := importer.Import(r.Context(), s.Service.Store, up, s.now())
	if err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sum)
}

// MARK: - Back-tests

func (s *Server) runBacktest(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var req backtest.Request
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "badRequest", err.Error())
		return
	}
	var weights *rating.Weights
	switch {
	case req.Weights != nil:
		if req.Weights.ID == "" {
			writeError(w, http.StatusBadRequest, "badRequest", "Supplied weights need an id.")
			return
		}
		if err := validateManualWeights(*req.Weights); err != nil {
			writeError(w, http.StatusBadRequest, "badRequest", err.Error())
			return
		}
		weights = req.Weights
	case req.WeightsID != "":
		weights, _ = s.Service.Store.Weights(ctx, req.WeightsID)
	default:
		weights, _ = s.Service.Store.ActiveWeights(ctx)
	}
	if weights == nil {
		writeError(w, http.StatusNotFound, "notFound", "No such weights.")
		return
	}
	if len(req.Variants) > 0 {
		sweep := backtest.SweepReport{Reports: make([]backtest.VariantReport, 0, len(req.Variants))}
		seen := map[string]bool{}
		for _, variant := range req.Variants {
			if seen[variant.Name] {
				writeError(w, http.StatusBadRequest, "badRequest", "Sweep variant names must be unique.")
				return
			}
			seen[variant.Name] = true
			candidate, err := backtest.ApplyOverrides(*weights, variant)
			if err != nil {
				writeError(w, http.StatusBadRequest, "badRequest", err.Error())
				return
			}
			variantRequest := req
			variantRequest.Variants = nil
			variantRequest.Weights = nil
			variantRequest.WeightsID = weights.ID
			report, err := backtest.Run(ctx, s.Service.Store, candidate, variantRequest)
			if err != nil {
				s.internal(w, err)
				return
			}
			if sweep.SharedCorpusID == "" {
				sweep.SharedCorpusID = report.CorpusID
			} else if sweep.SharedCorpusID != report.CorpusID {
				s.internal(w, errors.New("sweep variants used different race sets"))
				return
			}
			sweep.Reports = append(sweep.Reports, backtest.VariantReport{Name: variant.Name, Report: report})
		}
		id, err := s.Service.Store.SaveBacktest(ctx, weights.ID, req, sweep, s.now())
		if err != nil {
			s.internal(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "sweep": sweep})
		return
	}
	rep, err := backtest.Run(ctx, s.Service.Store, *weights, req)
	if err != nil {
		s.internal(w, err)
		return
	}
	id, err := s.Service.Store.SaveBacktest(ctx, weights.ID, req, rep, s.now())
	if err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "report": rep})
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
	if err := validateManualWeights(weights); err != nil {
		writeError(w, http.StatusBadRequest, "badRequest", err.Error())
		return
	}
	var suffix [8]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		s.internal(w, err)
		return
	}
	weights.ID = fmt.Sprintf("manual-%d-%x", s.now().Unix(), suffix[:])
	if err := s.Service.Store.InstallManualWeights(r.Context(), weights, s.now()); err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"weights": weights, "origin": "manual", "active": true})
}

func validateManualWeights(weights rating.Weights) error {
	finite := func(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }
	if weights.OverroundMethod != rating.Proportional && weights.OverroundMethod != rating.Power {
		return errors.New("invalid overroundMethod")
	}
	if !finite(weights.MarketExponent) || weights.MarketExponent <= 0 || weights.MarketExponent > 4 ||
		!finite(weights.FormInfluence) || weights.FormInfluence < 0 || weights.FormInfluence > 1 ||
		!finite(weights.FormInfluenceNoMarket) || weights.FormInfluenceNoMarket < 0 || weights.FormInfluenceNoMarket > 1 ||
		!finite(weights.Clip) || weights.Clip <= 0 || weights.Clip > 10 ||
		!finite(weights.MinimumMarketCoverage) || weights.MinimumMarketCoverage < 0 || weights.MinimumMarketCoverage > 1 ||
		!finite(weights.FormDecay) || weights.FormDecay < 0 || weights.FormDecay > 1 ||
		!finite(weights.FormSeasonBreakPenalty) || weights.FormSeasonBreakPenalty < 0 || weights.FormSeasonBreakPenalty > 1 ||
		!finite(weights.FormLongBreakPenalty) || weights.FormLongBreakPenalty < 0 || weights.FormLongBreakPenalty > 1 ||
		weights.FormMaxRuns < 1 || weights.FormMaxRuns > 20 || weights.MinimumStrikeRateSample < 30 ||
		!finite(weights.MinimumValueEdge) || weights.MinimumValueEdge < -1 || weights.MinimumValueEdge > 10 ||
		!finite(weights.MinimumValueProbability) || weights.MinimumValueProbability < 0 || weights.MinimumValueProbability > 1 {
		return errors.New("weight fields are outside valid ranges")
	}
	if len(weights.FactorWeights) != len(rating.AllFactors) || len(weights.FormPoints) != len(rating.DefaultFormPoints()) {
		return errors.New("factorWeights and formPoints must contain every supported key")
	}
	for _, id := range rating.AllFactors {
		value, ok := weights.FactorWeights[string(id)]
		if !ok || !finite(value) || value < 0 || value > 1 {
			return fmt.Errorf("invalid factor weight %q", id)
		}
	}
	for key := range rating.DefaultFormPoints() {
		value, ok := weights.FormPoints[key]
		if !ok || !finite(value) || value < 0 || value > 1 {
			return fmt.Errorf("invalid form point %q", key)
		}
	}
	return nil
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
	rows, err := s.Service.Store.Backtests(r.Context(), id)
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
		rows = []store.BacktestRow{}
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
	runs, _ := s.Service.Store.JobRuns(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{"job": name, "jobs": runs})
}
