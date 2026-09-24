package tracking

import (
	"sort"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
)

// SealWindow is how close to the off a tip stops being a draft.
const SealWindow = 5 * time.Minute

// RecordOutcome says what happened to a candidate tip.
type RecordOutcome string

const (
	Created               RecordOutcome = "created"
	Updated               RecordOutcome = "updated"
	Sealed                RecordOutcome = "sealed"
	RejectedAlreadySealed RecordOutcome = "rejectedAlreadySealed"
	RejectedRaceStarted   RecordOutcome = "rejectedRaceStarted"
	RejectedNoSelection   RecordOutcome = "rejectedNoSelection"
)

func (r RecordOutcome) DidStore() bool { return r == Created || r == Updated || r == Sealed }

// Decide applies the sealing rule, which is what makes the tracker mean
// anything:
//
//   - More than five minutes before the off, a new assessment overwrites the
//     draft. Prices move and non-runners are declared.
//   - Inside the last five minutes, the first write seals the record.
//   - Once the race has run, nothing is recorded at all.
//
// A race with no known off time is sealed on first write: better a slightly
// stale tip than a door left open to recording one after the result.
//
// It returns the tip to store, if any.
func Decide(existing *Tip, candidate Tip, now time.Time) (RecordOutcome, *Tip) {
	if existing != nil && existing.IsSealed() {
		return RejectedAlreadySealed, nil
	}
	if candidate.OffAt == nil {
		candidate.SealedAt = domain.Ptr(now)
		return Sealed, &candidate
	}
	off := candidate.OffAt.Time
	if !now.Before(off) {
		return RejectedRaceStarted, nil
	}
	if !now.Before(off.Add(-SealWindow)) {
		candidate.SealedAt = domain.Ptr(now)
		return Sealed, &candidate
	}
	if existing == nil {
		return Created, &candidate
	}
	return Updated, &candidate
}

// Ledger is an in-memory set of tips keyed by race. The server keeps tips in
// SQLite; this is what device uploads decode into and what the rules are
// tested against. Its JSON is TipLedger's: {"storage": {raceID: tip}}.
type Ledger struct {
	Storage map[string]Tip `json:"storage"`
}

func NewLedger(tips ...Tip) *Ledger {
	l := &Ledger{Storage: map[string]Tip{}}
	for _, t := range tips {
		l.Storage[t.RaceID] = t
	}
	return l
}

// Tips newest off first.
func (l *Ledger) Tips() []Tip {
	out := make([]Tip, 0, len(l.Storage))
	for _, t := range l.Storage {
		out = append(out, t)
	}
	SortTips(out)
	return out
}

// SortTips orders by off (or creation) time, newest first, then race id.
func SortTips(tips []Tip) {
	key := func(t Tip) time.Time {
		if t.OffAt != nil {
			return t.OffAt.Time
		}
		return t.CreatedAt.Time
	}
	sort.SliceStable(tips, func(i, j int) bool {
		a, b := key(tips[i]), key(tips[j])
		if a.Equal(b) {
			return tips[i].RaceID < tips[j].RaceID
		}
		return a.After(b)
	})
}

// Record rates-to-tip and applies the sealing rule.
func (l *Ledger) Record(a rating.Assessment, race domain.Race, ref *domain.MarketReference, now time.Time) RecordOutcome {
	candidate, ok := NewTip(a, race, ref, now)
	if !ok {
		return RejectedNoSelection
	}
	var existing *Tip
	if t, ok := l.Storage[candidate.RaceID]; ok {
		existing = &t
	}
	outcome, store := Decide(existing, candidate, now)
	if store != nil {
		l.Storage[store.RaceID] = *store
	}
	return outcome
}

// Settle applies an outcome unless the tip already has a final one.
func (l *Ledger) Settle(raceID string, outcome Outcome, favourite *FavouriteOutcome) bool {
	t, ok := l.Storage[raceID]
	if !ok {
		return false
	}
	if t.Outcome != nil && (t.Outcome.IsSettled() || t.Outcome.IsVoid()) {
		return false
	}
	t.Outcome = &outcome
	if favourite != nil {
		t.FavouriteOutcome = favourite
	}
	l.Storage[raceID] = t
	return true
}

// AwaitingReconciliation is true for a tip whose race has run and which has
// no final outcome yet.
func AwaitingReconciliation(t Tip, now time.Time) bool {
	if t.OffAt == nil || t.OffAt.After(now) {
		return false
	}
	return t.Outcome == nil || t.Outcome.Kind == Unresolved
}

// MarketIDsAwaitingStartingPrice are the Betfair markets a settled SP would
// still help, de-duplicated and sorted.
func MarketIDsAwaitingStartingPrice(tips []Tip, now time.Time) []string {
	set := map[string]bool{}
	for _, t := range tips {
		if AwaitingReconciliation(t, now) && t.MarketReference != nil {
			set[t.MarketReference.MarketID] = true
		}
	}
	out := make([]string, 0, len(set))
	for id := range set {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}
