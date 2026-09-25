// Package store is the server's SQLite database: the only copy of the history.
package store

import (
	"bytes"
	"compress/gzip"
	"context"
	"database/sql"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite" // pure Go, so the image needs no cgo

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/tracking"
	"github.com/bensuskins/races/server/internal/training"
)

//go:embed migrations/*.sql
var migrations embed.FS

// Store wraps one SQLite database. A single connection serialises every read
// and write, which for one user is simpler than it is slow, and means a tip
// write and a results ingest can never interleave.
type Store struct {
	db *sql.DB
}

const timeFormat = "2006-01-02T15:04:05Z"

func ts(t time.Time) string { return t.UTC().Format(timeFormat) }

func parseTS(s string) time.Time {
	t, _ := time.Parse(timeFormat, s)
	return t
}

// Open opens (creating if needed) and migrates the database. ":memory:" works
// for tests.
func Open(ctx context.Context, path string) (*Store, error) {
	dsn := "file:" + path + "?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)"
	if path != ":memory:" {
		dsn += "&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)"
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)`); err != nil {
		return err
	}
	entries, err := migrations.ReadDir("migrations")
	if err != nil {
		return err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		var done int
		if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations WHERE name = ?`, name).Scan(&done); err != nil {
			return err
		}
		if done > 0 {
			continue
		}
		body, err := migrations.ReadFile("migrations/" + name)
		if err != nil {
			return err
		}
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, string(body)); err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %s: %w", name, err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations (name, applied_at) VALUES (?, ?)`, name, ts(time.Now())); err != nil {
			tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

// Backup writes a consistent copy of the database to path, online.
func (s *Store) Backup(ctx context.Context, path string) error {
	_, err := s.db.ExecContext(ctx, `VACUUM INTO ?`, path)
	return err
}

func mustJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func gz(data []byte) []byte {
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	w.Write(data)
	w.Close()
	return buf.Bytes()
}

// Gunzip reverses the payload compression.
func Gunzip(data []byte) ([]byte, error) {
	r, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	return io.ReadAll(r)
}

// MARK: - Raw payloads

func (s *Store) SavePayload(ctx context.Context, provider, method, path, query string, status int, body []byte, at time.Time) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO raw_payloads (provider, method, path, query, status, fetched_at, body) VALUES (?,?,?,?,?,?,?)`,
		provider, method, path, query, status, ts(at), gz(body))
	return err
}

// Payload is one stored provider response.
type Payload struct {
	ID        int64     `json:"id"`
	Provider  string    `json:"provider"`
	Path      string    `json:"path"`
	Query     string    `json:"query"`
	Status    int       `json:"status"`
	FetchedAt time.Time `json:"fetchedAt"`
	Body      []byte    `json:"-"`
}

// Payloads returns stored responses for a provider and path, oldest first.
func (s *Store) Payloads(ctx context.Context, provider, path string) ([]Payload, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, provider, path, query, status, fetched_at, body FROM raw_payloads WHERE provider = ? AND path = ? ORDER BY id`, provider, path)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Payload
	for rows.Next() {
		var p Payload
		var at string
		var body []byte
		if err := rows.Scan(&p.ID, &p.Provider, &p.Path, &p.Query, &p.Status, &at, &body); err != nil {
			return nil, err
		}
		p.FetchedAt = parseTS(at)
		if p.Body, err = Gunzip(body); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// MARK: - Courses

func (s *Store) SaveCourses(ctx context.Context, courses []domain.Course, at time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	for _, c := range courses {
		if _, err := tx.ExecContext(ctx, `INSERT INTO courses (id, updated_at, json) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, json = excluded.json`, c.ID, ts(at), mustJSON(c)); err != nil {
			tx.Rollback()
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) Courses(ctx context.Context) ([]domain.Course, error) {
	return queryJSON[domain.Course](ctx, s.db, `SELECT json FROM courses ORDER BY json ->> '$.name' COLLATE NOCASE`)
}

// MARK: - Races

func (s *Store) SaveRaces(ctx context.Context, races []domain.Race, at time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	for _, r := range races {
		var off any
		if r.OffDateTime != nil {
			off = ts(r.OffDateTime.Time)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO races (id, date, course, off_at, updated_at, json) VALUES (?,?,?,?,?,?)
			ON CONFLICT(id) DO UPDATE SET date = excluded.date, course = excluded.course, off_at = excluded.off_at, updated_at = excluded.updated_at, json = excluded.json`,
			r.ID, r.Date, r.CourseName, off, ts(at), mustJSON(r)); err != nil {
			tx.Rollback()
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) RacesOn(ctx context.Context, date string) ([]domain.Race, error) {
	return queryJSON[domain.Race](ctx, s.db, `SELECT json FROM races WHERE date = ? ORDER BY off_at, id`, date)
}

// RacesOffBetween are races whose off falls in [from, to).
func (s *Store) RacesOffBetween(ctx context.Context, from, to time.Time) ([]domain.Race, error) {
	return queryJSON[domain.Race](ctx, s.db, `SELECT json FROM races WHERE off_at >= ? AND off_at < ? ORDER BY off_at, id`, ts(from), ts(to))
}

func (s *Store) Race(ctx context.Context, id string) (*domain.Race, error) {
	return queryOne[domain.Race](ctx, s.db, `SELECT json FROM races WHERE id = ?`, id)
}

// RacecardsFetchedAt is when a day's card was last refreshed.
func (s *Store) RacecardsFetchedAt(ctx context.Context, date string) (time.Time, bool) {
	var at sql.NullString
	s.db.QueryRowContext(ctx, `SELECT MAX(updated_at) FROM races WHERE date = ?`, date).Scan(&at)
	if !at.Valid {
		return time.Time{}, false
	}
	return parseTS(at.String), true
}

// MARK: - Results

func (s *Store) SaveResults(ctx context.Context, results []domain.RaceResult, at time.Time) (int, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	fresh := 0
	for _, r := range results {
		res, err := tx.ExecContext(ctx, `INSERT INTO results (race_id, date, fetched_at, json) VALUES (?,?,?,?)
			ON CONFLICT(race_id) DO UPDATE SET fetched_at = excluded.fetched_at, json = excluded.json
			WHERE json_array_length(excluded.json, '$.finishers') >= json_array_length(results.json, '$.finishers')`,
			r.ID, r.Date, ts(at), mustJSON(r))
		if err != nil {
			tx.Rollback()
			return 0, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			fresh++
			if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO result_facts (race_id, known_at, json) VALUES (?,?,?)`, r.ID, ts(at), mustJSON(r)); err != nil {
				tx.Rollback()
				return 0, err
			}
		}
	}
	return fresh, tx.Commit()
}

// ResultFactsKnownBefore returns the latest version of each result known by a
// given time. It never includes facts collected after that time.
func (s *Store) ResultFactsKnownBefore(ctx context.Context, cutoff time.Time) ([]domain.RaceResult, error) {
	return queryJSON[domain.RaceResult](ctx, s.db, `SELECT facts.json FROM result_facts AS facts
		JOIN (SELECT race_id, MAX(known_at) AS known_at FROM result_facts WHERE known_at < ? GROUP BY race_id) AS latest
		ON latest.race_id = facts.race_id AND latest.known_at = facts.known_at ORDER BY facts.race_id`, ts(cutoff))
}

func (s *Store) Result(ctx context.Context, raceID string) (*domain.RaceResult, error) {
	return queryOne[domain.RaceResult](ctx, s.db, `SELECT json FROM results WHERE race_id = ?`, raceID)
}

func (s *Store) ResultsOn(ctx context.Context, date string) ([]domain.RaceResult, error) {
	return queryJSON[domain.RaceResult](ctx, s.db, `SELECT json FROM results WHERE date = ? ORDER BY race_id`, date)
}

// MARK: - Market matches and snapshots

// MatchRow is a race's current market, or why it has none.
type MatchRow struct {
	RaceID    string                  `json:"raceID"`
	MarketID  string                  `json:"marketID,omitempty"`
	MatchedAt time.Time               `json:"-"`
	Reference *domain.MarketReference `json:"reference,omitempty"`
	Refusal   json.RawMessage         `json:"refusal,omitempty"`
}

func (s *Store) SaveMatch(ctx context.Context, m MatchRow) error {
	var ref, refusal, market any
	if m.Reference != nil {
		ref, market = mustJSON(m.Reference), m.Reference.MarketID
	}
	if len(m.Refusal) > 0 {
		refusal = string(m.Refusal)
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO market_matches (race_id, market_id, matched_at, reference_json, refusal_json) VALUES (?,?,?,?,?)
		ON CONFLICT(race_id) DO UPDATE SET market_id = excluded.market_id, matched_at = excluded.matched_at, reference_json = excluded.reference_json, refusal_json = excluded.refusal_json`,
		m.RaceID, market, ts(m.MatchedAt), ref, refusal)
	return err
}

func (s *Store) Matches(ctx context.Context, raceIDs []string) (map[string]MatchRow, error) {
	out := map[string]MatchRow{}
	if len(raceIDs) == 0 {
		return out, nil
	}
	args := make([]any, len(raceIDs))
	for i, id := range raceIDs {
		args[i] = id
	}
	rows, err := s.db.QueryContext(ctx, `SELECT race_id, COALESCE(market_id,''), matched_at, reference_json, refusal_json FROM market_matches WHERE race_id IN (`+placeholders(len(raceIDs))+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var m MatchRow
		var at string
		var ref, refusal sql.NullString
		if err := rows.Scan(&m.RaceID, &m.MarketID, &at, &ref, &refusal); err != nil {
			return nil, err
		}
		m.MatchedAt = parseTS(at)
		if ref.Valid {
			var r domain.MarketReference
			if json.Unmarshal([]byte(ref.String), &r) == nil {
				m.Reference = &r
			}
		}
		if refusal.Valid {
			m.Refusal = json.RawMessage(refusal.String)
		}
		out[m.RaceID] = m
	}
	return out, rows.Err()
}

func (s *Store) SaveSnapshot(ctx context.Context, raceID, kind string, snap domain.MarketSnapshot) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO market_snapshots (race_id, kind, captured_at, json) VALUES (?,?,?,?)`, raceID, kind, ts(snap.CapturedAt.Time), mustJSON(snap))
	if err == nil && kind == "display" {
		// Only the latest display snapshot is worth keeping.
		_, err = s.db.ExecContext(ctx, `DELETE FROM market_snapshots WHERE race_id = ? AND kind = 'display' AND id NOT IN (SELECT MAX(id) FROM market_snapshots WHERE race_id = ? AND kind = 'display')`, raceID, raceID)
	}
	return err
}

// LatestSnapshot of a kind for a race.
func (s *Store) LatestSnapshot(ctx context.Context, raceID, kind string) (*domain.MarketSnapshot, error) {
	return queryOne[domain.MarketSnapshot](ctx, s.db, `SELECT json FROM market_snapshots WHERE race_id = ? AND kind = ? ORDER BY id DESC LIMIT 1`, raceID, kind)
}

func (s *Store) SaveStartingPrices(ctx context.Context, sps map[string]map[int64]float64, at time.Time) error {
	for market, bySel := range sps {
		for sel, bsp := range bySel {
			if _, err := s.db.ExecContext(ctx, `INSERT INTO starting_prices (market_id, selection_id, bsp, fetched_at) VALUES (?,?,?,?) ON CONFLICT DO UPDATE SET bsp = excluded.bsp, fetched_at = excluded.fetched_at`, market, sel, bsp, ts(at)); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Store) StartingPrices(ctx context.Context, marketIDs []string) (map[string]map[int64]float64, error) {
	out := map[string]map[int64]float64{}
	if len(marketIDs) == 0 {
		return out, nil
	}
	args := make([]any, len(marketIDs))
	for i, id := range marketIDs {
		args[i] = id
	}
	rows, err := s.db.QueryContext(ctx, `SELECT market_id, selection_id, bsp FROM starting_prices WHERE market_id IN (`+placeholders(len(marketIDs))+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var m string
		var sel int64
		var bsp float64
		if err := rows.Scan(&m, &sel, &bsp); err != nil {
			return nil, err
		}
		if out[m] == nil {
			out[m] = map[int64]float64{}
		}
		out[m][sel] = bsp
	}
	return out, rows.Err()
}

// MARK: - Assessments

func (s *Store) SaveAssessment(ctx context.Context, a rating.Assessment) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO assessments (race_id, generated_at, weights_id, json) VALUES (?,?,?,?)
		ON CONFLICT(race_id) DO UPDATE SET generated_at = excluded.generated_at, weights_id = excluded.weights_id, json = excluded.json`,
		a.RaceID, ts(a.GeneratedAt.Time), a.WeightsID, mustJSON(a))
	return err
}

func (s *Store) Assessment(ctx context.Context, raceID string) (*rating.Assessment, error) {
	return queryOne[rating.Assessment](ctx, s.db, `SELECT json FROM assessments WHERE race_id = ?`, raceID)
}

func (s *Store) AssessmentsOn(ctx context.Context, date string) (map[string]rating.Assessment, error) {
	list, err := queryJSON[rating.Assessment](ctx, s.db, `SELECT a.json FROM assessments a JOIN races r ON r.id = a.race_id WHERE r.date = ?`, date)
	out := map[string]rating.Assessment{}
	for _, a := range list {
		out[a.RaceID] = a
	}
	return out, err
}

// MARK: - Tips

// TipRow is a tip plus where it came from.
type TipRow struct {
	Tip    tracking.Tip
	Source string
}

func (s *Store) SaveTip(ctx context.Context, t tracking.Tip, source string, at time.Time) error {
	return saveTip(ctx, s.db, t, source, at)
}

// SaveSealedTip stores the seal card and tip atomically. The first card for a
// race remains fixed even if a later refresh changes the current card.
func (s *Store) SaveSealedTip(ctx context.Context, t tracking.Tip, race domain.Race, source string, at time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO seal_cards (race_id, version, captured_at, json) VALUES (?,1,?,?) ON CONFLICT(race_id) DO NOTHING`, race.ID, ts(at), mustJSON(race)); err != nil {
		tx.Rollback()
		return err
	}
	if err := saveTip(ctx, tx, t, source, at); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

// SealCard returns the immutable race card used at seal time.
func (s *Store) SealCard(ctx context.Context, raceID string) (*domain.Race, error) {
	return queryOne[domain.Race](ctx, s.db, `SELECT json FROM seal_cards WHERE race_id = ?`, raceID)
}

type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func saveTip(ctx context.Context, db execer, t tracking.Tip, source string, at time.Time) error {
	var off, sealed, outcome any
	if t.OffAt != nil {
		off = ts(t.OffAt.Time)
	}
	if t.SealedAt != nil {
		sealed = ts(t.SealedAt.Time)
	}
	if t.Outcome != nil {
		outcome = t.Outcome.Kind
	}
	_, err := db.ExecContext(ctx, `INSERT INTO tips (race_id, race_date, off_at, weights_id, sealed_at, outcome_kind, source, updated_at, json) VALUES (?,?,?,?,?,?,?,?,?)
		ON CONFLICT(race_id) DO UPDATE SET race_date = excluded.race_date, off_at = excluded.off_at, weights_id = excluded.weights_id, sealed_at = excluded.sealed_at,
		outcome_kind = excluded.outcome_kind, source = excluded.source, updated_at = excluded.updated_at, json = excluded.json`,
		t.RaceID, t.RaceDate, off, t.WeightsID, sealed, outcome, source, ts(at), mustJSON(t))
	return err
}

func (s *Store) Tip(ctx context.Context, raceID string) (*TipRow, error) {
	rows, err := s.tipRows(ctx, `WHERE race_id = ?`, raceID)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// Tips optionally filtered by weights id and date; newest off first.
func (s *Store) Tips(ctx context.Context, weightsID, date string) ([]TipRow, error) {
	var clauses []string
	var args []any
	if weightsID != "" {
		clauses, args = append(clauses, "weights_id = ?"), append(args, weightsID)
	}
	if date != "" {
		clauses, args = append(clauses, "race_date = ?"), append(args, date)
	}
	where := ""
	if len(clauses) > 0 {
		where = "WHERE " + strings.Join(clauses, " AND ")
	}
	rows, err := s.tipRows(ctx, where, args...)
	if err != nil {
		return nil, err
	}
	tips := make([]tracking.Tip, len(rows))
	bySource := map[string]string{}
	for i, r := range rows {
		tips[i] = r.Tip
		bySource[r.Tip.RaceID] = r.Source
	}
	tracking.SortTips(tips)
	for i, t := range tips {
		rows[i] = TipRow{Tip: t, Source: bySource[t.RaceID]}
	}
	return rows, nil
}

// AwaitingReconciliation are tips whose race has run with no final outcome.
func (s *Store) AwaitingReconciliation(ctx context.Context, now time.Time) ([]TipRow, error) {
	return s.tipRows(ctx, `WHERE off_at IS NOT NULL AND off_at <= ? AND (outcome_kind IS NULL OR outcome_kind = 'unresolved')`, ts(now))
}

func (s *Store) tipRows(ctx context.Context, where string, args ...any) ([]TipRow, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT json, source FROM tips `+where, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TipRow
	for rows.Next() {
		var raw, source string
		if err := rows.Scan(&raw, &source); err != nil {
			return nil, err
		}
		var t tracking.Tip
		if err := json.Unmarshal([]byte(raw), &t); err != nil {
			return nil, err
		}
		out = append(out, TipRow{Tip: t, Source: source})
	}
	return out, rows.Err()
}

// WeightsIDsInUse lists weights ids stamped on tips, with counts.
func (s *Store) WeightsIDsInUse(ctx context.Context) (map[string]int, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT weights_id, COUNT(*) FROM tips GROUP BY weights_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var id string
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			return nil, err
		}
		out[id] = n
	}
	return out, rows.Err()
}

// MARK: - Weights

// WeightsRow is a stored weight set.
type WeightsRow struct {
	Weights   rating.Weights `json:"weights"`
	Origin    string         `json:"origin"`
	CreatedAt domain.Instant `json:"createdAt"`
	Active    bool           `json:"active"`
}

// EnsureWeights inserts a set if its id is new. Existing ids are never
// overwritten: an id names one set of numbers forever.
func (s *Store) EnsureWeights(ctx context.Context, w rating.Weights, origin string, at time.Time) (bool, error) {
	res, err := s.db.ExecContext(ctx, `INSERT INTO weights (id, origin, created_at, active, json) VALUES (?,?,?,0,?) ON CONFLICT(id) DO NOTHING`, w.ID, origin, ts(at), mustJSON(w))
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

func (s *Store) SetActiveWeights(ctx context.Context, id string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	res, err := tx.ExecContext(ctx, `UPDATE weights SET active = CASE WHEN id = ? THEN 1 ELSE 0 END`, id)
	if err == nil {
		var count int
		tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM weights WHERE id = ?`, id).Scan(&count)
		if count == 0 {
			err = fmt.Errorf("no weights %q", id)
		}
	}
	_ = res
	if err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

// InstallManualWeights stores a new immutable set and activates it atomically.
func (s *Store) InstallManualWeights(ctx context.Context, weights rating.Weights, at time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO weights (id, origin, created_at, active, json) VALUES (?, 'manual', ?, 0, ?)`, weights.ID, ts(at), mustJSON(weights)); err != nil {
		tx.Rollback()
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE weights SET active = CASE WHEN id = ? THEN 1 ELSE 0 END`, weights.ID); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

func (s *Store) AllWeights(ctx context.Context) ([]WeightsRow, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT json, origin, created_at, active FROM weights ORDER BY created_at, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []WeightsRow
	for rows.Next() {
		var raw, origin, at string
		var active int
		if err := rows.Scan(&raw, &origin, &at, &active); err != nil {
			return nil, err
		}
		var w rating.Weights
		if err := json.Unmarshal([]byte(raw), &w); err != nil {
			return nil, err
		}
		out = append(out, WeightsRow{Weights: w, Origin: origin, CreatedAt: domain.At(parseTS(at)), Active: active == 1})
	}
	return out, rows.Err()
}

func (s *Store) Weights(ctx context.Context, id string) (*rating.Weights, error) {
	return queryOne[rating.Weights](ctx, s.db, `SELECT json FROM weights WHERE id = ?`, id)
}

func (s *Store) ActiveWeights(ctx context.Context) (*rating.Weights, error) {
	return queryOne[rating.Weights](ctx, s.db, `SELECT json FROM weights WHERE active = 1 LIMIT 1`)
}

// MARK: - Training samples

func (s *Store) SaveTrainingSnapshot(ctx context.Context, snap rating.TrainingSnapshot, source string) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO training_samples (race_id, created_at, winner_id, source, json) VALUES (?,?,NULL,?,?)
		ON CONFLICT(race_id) DO UPDATE SET created_at = excluded.created_at, json = excluded.json WHERE training_samples.winner_id IS NULL`,
		snap.RaceID, ts(snap.CreatedAt.Time), source, mustJSON(snap))
	return err
}

// SetTrainingWinner attaches the result to a pending snapshot.
func (s *Store) SetTrainingWinner(ctx context.Context, raceID, winnerID string) (bool, error) {
	res, err := s.db.ExecContext(ctx, `UPDATE training_samples SET winner_id = ? WHERE race_id = ? AND winner_id IS NULL AND EXISTS (SELECT 1 FROM json_each(training_samples.json, '$.runnerIDs') WHERE json_each.value = ?)`, winnerID, raceID, winnerID)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// InsertTrainingSample adds a settled sample if the race is new.
func (s *Store) InsertTrainingSample(ctx context.Context, sample training.Race, source string) (bool, error) {
	res, err := s.db.ExecContext(ctx, `INSERT INTO training_samples (race_id, created_at, winner_id, source, json) VALUES (?,?,?,?,?) ON CONFLICT(race_id) DO NOTHING`,
		sample.Snapshot.RaceID, ts(sample.Snapshot.CreatedAt.Time), nullable(sample.WinnerID), source, mustJSON(sample.Snapshot))
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// SettledTrainingSamples, oldest first, optionally within [from, to).
func (s *Store) SettledTrainingSamples(ctx context.Context, from, to time.Time) ([]training.Race, error) {
	q := `SELECT json, winner_id FROM training_samples WHERE winner_id IS NOT NULL`
	var args []any
	if !from.IsZero() {
		q, args = q+` AND created_at >= ?`, append(args, ts(from))
	}
	if !to.IsZero() {
		q, args = q+` AND created_at < ?`, append(args, ts(to))
	}
	rows, err := s.db.QueryContext(ctx, q+` ORDER BY created_at, race_id`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []training.Race
	for rows.Next() {
		var raw, winner string
		if err := rows.Scan(&raw, &winner); err != nil {
			return nil, err
		}
		var snap rating.TrainingSnapshot
		if err := json.Unmarshal([]byte(raw), &snap); err != nil {
			return nil, err
		}
		out = append(out, training.Race{Snapshot: snap, WinnerID: winner})
	}
	return out, rows.Err()
}

// TrainingCounts is settled and pending sample counts.
func (s *Store) TrainingCounts(ctx context.Context) (settled, pending int) {
	s.db.QueryRowContext(ctx, `SELECT COUNT(*) FILTER (WHERE winner_id IS NOT NULL), COUNT(*) FILTER (WHERE winner_id IS NULL) FROM training_samples`).Scan(&settled, &pending)
	return
}

// MARK: - Documents

func (s *Store) SaveDocument(ctx context.Context, name string, v any, at time.Time) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO documents (name, updated_at, json) VALUES (?,?,?) ON CONFLICT(name) DO UPDATE SET updated_at = excluded.updated_at, json = excluded.json`, name, ts(at), mustJSON(v))
	return err
}

// LoadDocument decodes a document into v; false if absent.
func (s *Store) LoadDocument(ctx context.Context, name string, v any) (bool, error) {
	var raw string
	err := s.db.QueryRowContext(ctx, `SELECT json FROM documents WHERE name = ?`, name).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, json.Unmarshal([]byte(raw), v)
}

// MARK: - Back-tests, imports, job runs

func (s *Store) SaveBacktest(ctx context.Context, weightsID string, request, report any, at time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx, `INSERT INTO backtests (created_at, weights_id, request, report) VALUES (?,?,?,?)`, ts(at), weightsID, mustJSON(request), mustJSON(report))
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// BacktestRow is a stored back-test.
type BacktestRow struct {
	ID        int64           `json:"id"`
	CreatedAt domain.Instant  `json:"createdAt"`
	WeightsID string          `json:"weightsID"`
	Request   json.RawMessage `json:"request"`
	Report    json.RawMessage `json:"report"`
}

func (s *Store) Backtests(ctx context.Context, id int64) ([]BacktestRow, error) {
	q := `SELECT id, created_at, weights_id, request, report FROM backtests`
	var args []any
	if id > 0 {
		q, args = q+` WHERE id = ?`, append(args, id)
	}
	rows, err := s.db.QueryContext(ctx, q+` ORDER BY id DESC LIMIT 100`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BacktestRow
	for rows.Next() {
		var b BacktestRow
		var at, req, rep string
		if err := rows.Scan(&b.ID, &at, &b.WeightsID, &req, &rep); err != nil {
			return nil, err
		}
		b.CreatedAt, b.Request, b.Report = domain.At(parseTS(at)), json.RawMessage(req), json.RawMessage(rep)
		out = append(out, b)
	}
	return out, rows.Err()
}

func (s *Store) SaveImport(ctx context.Context, device string, summary any, raw []byte, at time.Time) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO imports (device, received_at, summary, raw) VALUES (?,?,?,?)`, device, ts(at), mustJSON(summary), gz(raw))
	return err
}

// JobRun is the last run of a scheduled job.
type JobRun struct {
	Name        string          `json:"name"`
	StartedAt   *domain.Instant `json:"startedAt,omitempty"`
	FinishedAt  *domain.Instant `json:"finishedAt,omitempty"`
	SucceededAt *domain.Instant `json:"succeededAt,omitempty"`
	Error       string          `json:"error,omitempty"`
	Summary     string          `json:"summary,omitempty"`
}

func (s *Store) JobStarted(ctx context.Context, name string, at time.Time) {
	s.db.ExecContext(ctx, `INSERT INTO job_runs (name, started_at) VALUES (?,?) ON CONFLICT(name) DO UPDATE SET started_at = excluded.started_at`, name, ts(at))
}

func (s *Store) JobFinished(ctx context.Context, name string, at time.Time, summary string, jobErr error) {
	if jobErr != nil {
		s.db.ExecContext(ctx, `UPDATE job_runs SET finished_at = ?, error = ?, summary = ? WHERE name = ?`, ts(at), jobErr.Error(), summary, name)
		return
	}
	s.db.ExecContext(ctx, `UPDATE job_runs SET finished_at = ?, succeeded_at = ?, error = NULL, summary = ? WHERE name = ?`, ts(at), ts(at), summary, name)
}

func (s *Store) JobRuns(ctx context.Context) ([]JobRun, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT name, started_at, finished_at, succeeded_at, COALESCE(error,''), COALESCE(summary,'') FROM job_runs ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []JobRun
	for rows.Next() {
		var j JobRun
		var started, finished, succeeded sql.NullString
		if err := rows.Scan(&j.Name, &started, &finished, &succeeded, &j.Error, &j.Summary); err != nil {
			return nil, err
		}
		for _, p := range []struct {
			src sql.NullString
			dst **domain.Instant
		}{{started, &j.StartedAt}, {finished, &j.FinishedAt}, {succeeded, &j.SucceededAt}} {
			if p.src.Valid {
				*p.dst = domain.Ptr(parseTS(p.src.String))
			}
		}
		out = append(out, j)
	}
	return out, rows.Err()
}

// Counts for /metrics and /v1/status.
type Counts struct {
	Races, Results, Tips, SealedTips, SettledTips, Payloads, TrainingSettled, TrainingPending int
}

func (s *Store) Counts(ctx context.Context) Counts {
	var c Counts
	s.db.QueryRowContext(ctx, `SELECT (SELECT COUNT(*) FROM races), (SELECT COUNT(*) FROM results), (SELECT COUNT(*) FROM tips),
		(SELECT COUNT(*) FROM tips WHERE sealed_at IS NOT NULL), (SELECT COUNT(*) FROM tips WHERE outcome_kind IN ('won','lost')),
		(SELECT COUNT(*) FROM raw_payloads)`).Scan(&c.Races, &c.Results, &c.Tips, &c.SealedTips, &c.SettledTips, &c.Payloads)
	c.TrainingSettled, c.TrainingPending = s.TrainingCounts(ctx)
	return c
}

// MARK: - helpers

func placeholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

type queryer interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

func queryJSON[T any](ctx context.Context, db queryer, q string, args ...any) ([]T, error) {
	rows, err := db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []T
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var v T
		if err := json.Unmarshal([]byte(raw), &v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func queryOne[T any](ctx context.Context, db queryer, q string, args ...any) (*T, error) {
	list, err := queryJSON[T](ctx, db, q, args...)
	if err != nil || len(list) == 0 {
		return nil, err
	}
	return &list[0], nil
}

// Tx runs fn in a transaction, for the importer.
func (s *Store) Tx(ctx context.Context, fn func(tx *Tx) error) error {
	sqlTx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(&Tx{tx: sqlTx}); err != nil {
		sqlTx.Rollback()
		return err
	}
	return sqlTx.Commit()
}

// Tx exposes the writes an import needs, atomically.
type Tx struct{ tx *sql.Tx }

func (t *Tx) Tip(ctx context.Context, raceID string) (*TipRow, error) {
	var raw, source string
	err := t.tx.QueryRowContext(ctx, `SELECT json, source FROM tips WHERE race_id = ?`, raceID).Scan(&raw, &source)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var tip tracking.Tip
	if err := json.Unmarshal([]byte(raw), &tip); err != nil {
		return nil, err
	}
	return &TipRow{Tip: tip, Source: source}, nil
}

func (t *Tx) SaveTip(ctx context.Context, tip tracking.Tip, source string, at time.Time) error {
	return saveTip(ctx, t.tx, tip, source, at)
}
