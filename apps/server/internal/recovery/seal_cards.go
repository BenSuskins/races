// Package recovery reconstructs legacy seal cards from retained racecard
// responses when the original rating can be reproduced exactly.
package recovery

import (
	"context"
	"fmt"
	"reflect"
	"sort"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/racingapi"
	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/store"
	"github.com/bensuskins/races/server/internal/tracking"
)

const racecardsPath = "/v1/racecards/free"

type Status string

const (
	Recoverable   Status = "recoverable"
	Recovered     Status = "recovered"
	Ambiguous     Status = "ambiguous"
	Unrecoverable Status = "unrecoverable"
)

type Entry struct {
	RaceID     string    `json:"raceID"`
	Status     Status    `json:"status"`
	Reason     string    `json:"reason"`
	PayloadID  int64     `json:"payloadID,omitempty"`
	CapturedAt time.Time `json:"capturedAt,omitempty"`
}

type Report struct {
	TipsChecked    int     `json:"tipsChecked"`
	Recoverable    int     `json:"recoverable"`
	Recovered      int     `json:"recovered"`
	Ambiguous      int     `json:"ambiguous"`
	Unrecoverable  int     `json:"unrecoverable"`
	ApplyRequested bool    `json:"applyRequested"`
	Entries        []Entry `json:"entries"`
}

type cardCandidate struct {
	payload store.Payload
	race    domain.Race
}

// SealCards reports legacy server tips whose original rated card can be
// recreated exactly. When apply is true, it inserts only verified missing
// cards and records the source payload for each insert.
func SealCards(ctx context.Context, st *store.Store, apply bool, recoveredAt time.Time) (Report, error) {
	report := Report{ApplyRequested: apply, Entries: []Entry{}}
	payloads, err := st.Payloads(ctx, "racingapi", racecardsPath)
	if err != nil {
		return report, err
	}
	candidates := make(map[string][]cardCandidate)
	for _, payload := range payloads {
		if payload.Method != "GET" || payload.Status < 200 || payload.Status >= 300 {
			continue
		}
		races, err := racingapi.ParseRacecards(payload.Body, payload.FetchedAt)
		if err != nil {
			continue
		}
		for _, race := range races {
			candidates[race.ID] = append(candidates[race.ID], cardCandidate{payload: payload, race: race})
		}
	}

	tips, err := st.Tips(ctx, "", "")
	if err != nil {
		return report, err
	}
	for _, row := range tips {
		tip := row.Tip
		if row.Source != "server" || !tip.IsSealed() {
			continue
		}
		card, err := st.SealCard(ctx, tip.RaceID)
		if err != nil {
			return report, err
		}
		if card != nil {
			continue
		}
		report.TipsChecked++
		entry, candidate, err := verifyCandidate(ctx, st, tip, candidates[tip.RaceID])
		if err != nil {
			return report, err
		}
		if entry.Status == Recoverable && apply {
			inserted, err := st.SaveRecoveredSealCard(ctx, candidate.race,
				entry.PayloadID, entry.CapturedAt, recoveredAt)
			if err != nil {
				return report, fmt.Errorf("recover seal card for %s: %w", tip.RaceID, err)
			}
			if inserted {
				entry.Status = Recovered
				entry.Reason = "The stored tip exactly matches the card and its source payload is recorded."
			} else {
				entry.Status = Ambiguous
				entry.Reason = "A seal card appeared during recovery; no existing card was changed."
			}
		}
		switch entry.Status {
		case Recoverable:
			report.Recoverable++
		case Recovered:
			report.Recovered++
		case Ambiguous:
			report.Ambiguous++
		case Unrecoverable:
			report.Unrecoverable++
		}
		report.Entries = append(report.Entries, entry)
	}
	sort.Slice(report.Entries, func(i, j int) bool { return report.Entries[i].RaceID < report.Entries[j].RaceID })
	return report, nil
}

func verifyCandidate(ctx context.Context, st *store.Store, tip tracking.Tip, available []cardCandidate) (Entry, *cardCandidate, error) {
	entry := Entry{RaceID: tip.RaceID, Status: Unrecoverable, Reason: "No successful racecard payload with this race ID predates the seal."}
	if tip.SealedAt == nil {
		entry.Reason = "The tip has no seal time."
		return entry, nil, nil
	}
	var candidate *cardCandidate
	for i := range available {
		item := &available[i]
		if !item.payload.FetchedAt.Before(tip.SealedAt.Time) {
			continue
		}
		if candidate == nil || item.payload.FetchedAt.After(candidate.payload.FetchedAt) ||
			(item.payload.FetchedAt.Equal(candidate.payload.FetchedAt) && item.payload.ID > candidate.payload.ID) {
			candidate = item
		}
	}
	if candidate == nil {
		return entry, nil, nil
	}
	entry.PayloadID = candidate.payload.ID
	entry.CapturedAt = candidate.payload.FetchedAt
	entry.Status = Ambiguous
	entry.Reason = "Retained cards differ before the seal, so the persisted card cannot be proven."
	for _, item := range available {
		if item.payload.FetchedAt.After(tip.SealedAt.Time) {
			continue
		}
		if !reflect.DeepEqual(item.race, candidate.race) {
			return entry, candidate, nil
		}
	}
	weights, err := st.Weights(ctx, tip.WeightsID)
	if err != nil {
		return entry, candidate, err
	}
	if weights == nil {
		entry.Reason = "The weight set used by this tip is no longer stored."
		return entry, candidate, nil
	}
	snapshot, err := st.LatestSnapshot(ctx, tip.RaceID, "seal")
	if err != nil {
		return entry, candidate, err
	}
	facts, err := st.ResultFactsKnownBefore(ctx, tip.SealedAt.Time)
	if err != nil {
		return entry, candidate, err
	}
	archive := tracking.NewArchive()
	for _, fact := range facts {
		if fact.ID != tip.RaceID {
			archive.Ingest(fact)
		}
	}
	assessment := rating.NewRater(*weights).Rate(candidate.race, snapshot, archive, tip.SealedAt.Time)
	recreated, ok := tracking.NewTip(assessment, candidate.race, tip.MarketReference, tip.CreatedAt.Time)
	if !ok {
		entry.Reason = "The candidate card does not produce a selection."
		return entry, candidate, nil
	}
	recreated.SealedAt = tip.SealedAt
	recreated.Outcome = tip.Outcome
	recreated.FavouriteOutcome = tip.FavouriteOutcome
	if !reflect.DeepEqual(recreated, tip) {
		entry.Reason = "The candidate card does not reproduce the stored tip exactly."
		return entry, candidate, nil
	}
	entry.Status = Recoverable
	entry.Reason = "All retained pre-seal cards are identical, and the card reproduces every stored tip field exactly."
	return entry, candidate, nil
}
