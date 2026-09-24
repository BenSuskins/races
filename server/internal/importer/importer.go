// Package importer takes the history a phone collected before the server
// existed — the JSON documents RacesStore wrote to Application Support — and
// folds it into the database.
//
// The app uploads the files unchanged. Each is a StoredDocument envelope,
// {schemaVersion, savedAt, payload}, whose payload is Swift's synthesised
// Codable output; the Go types in tracking, rating and training decode it
// because they were written to that shape.
package importer

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/store"
	"github.com/bensuskins/races/server/internal/tracking"
	"github.com/bensuskins/races/server/internal/training"
)

// Upload is the request body of POST /v1/import.
type Upload struct {
	Device   string          `json:"device"`
	Tips     json.RawMessage `json:"tips,omitempty"`
	Archive  json.RawMessage `json:"archive,omitempty"`
	Training json.RawMessage `json:"training,omitempty"`
}

// Summary says what an import changed. A repeat upload reports zeros.
type Summary struct {
	Device              string   `json:"device"`
	TipsReceived        int      `json:"tipsReceived"`
	TipsAdded           int      `json:"tipsAdded"`
	TipsReplaced        int      `json:"tipsReplaced"`
	TipsKept            int      `json:"tipsKept"`
	ArchiveRacesAdded   int      `json:"archiveRacesAdded"`
	ArchiveSkipped      bool     `json:"archiveSkipped"`
	SamplesReceived     int      `json:"samplesReceived"`
	SamplesAdded        int      `json:"samplesAdded"`
	PendingAdded        int      `json:"pendingAdded"`
	WeightsAdded        []string `json:"weightsAdded"`
	UnreadableDocuments []string `json:"unreadableDocuments"`
}

// envelope is StoredDocument<T>.
type envelope[T any] struct {
	SchemaVersion int `json:"schemaVersion"`
	Payload       T   `json:"payload"`
}

func decode[T any](raw json.RawMessage) (*T, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var e envelope[T]
	if err := json.Unmarshal(raw, &e); err != nil {
		return nil, err
	}
	if e.SchemaVersion != 1 {
		return nil, fmt.Errorf("schema version %d", e.SchemaVersion)
	}
	return &e.Payload, nil
}

// deviceTraining is OnDeviceTrainingState.
type deviceTraining struct {
	Samples          []training.Race                    `json:"samples"`
	PendingSnapshots map[string]rating.TrainingSnapshot `json:"pendingSnapshots"`
	ActiveWeights    *rating.Weights                    `json:"activeWeights"`
}

const archiveDocument = "archive"

// Import folds one upload into the store.
//
// Tips: a server tip always wins, because the server sealed it itself. Between
// two device copies of the same race — two phones — a sealed tip beats a
// draft, and the earlier seal wins, because that is the one made first with
// less information. Everything else is added with source device:<name>.
func Import(ctx context.Context, st *store.Store, up Upload, now time.Time) (Summary, error) {
	if up.Device == "" {
		up.Device = "unknown"
	}
	source := "device:" + up.Device
	sum := Summary{Device: up.Device, WeightsAdded: []string{}, UnreadableDocuments: []string{}}

	ledger, err := decode[tracking.Ledger](up.Tips)
	if err != nil {
		sum.UnreadableDocuments = append(sum.UnreadableDocuments, "tips: "+err.Error())
	}
	archive, err := decode[tracking.Archive](up.Archive)
	if err != nil {
		sum.UnreadableDocuments = append(sum.UnreadableDocuments, "archive: "+err.Error())
	}
	state, err := decode[deviceTraining](up.Training)
	if err != nil {
		sum.UnreadableDocuments = append(sum.UnreadableDocuments, "training: "+err.Error())
	}

	if ledger != nil {
		ids := make([]string, 0, len(ledger.Storage))
		for id := range ledger.Storage {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		sum.TipsReceived = len(ids)
		err := st.Tx(ctx, func(tx *store.Tx) error {
			for _, id := range ids {
				tip := ledger.Storage[id]
				if tip.RaceID == "" {
					tip.RaceID = id
				}
				existing, err := tx.Tip(ctx, tip.RaceID)
				if err != nil {
					return err
				}
				switch {
				case existing == nil:
					sum.TipsAdded++
				case prefer(tip, *existing):
					sum.TipsReplaced++
				default:
					sum.TipsKept++
					continue
				}
				if err := tx.SaveTip(ctx, tip, source, now); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			return sum, err
		}
	}

	if archive != nil {
		current := tracking.NewArchive()
		if _, err := st.LoadDocument(ctx, archiveDocument, current); err != nil {
			return sum, err
		}
		fresh := 0
		for _, id := range archive.IngestedRaceIDs {
			if !current.Has(id) {
				fresh++
			}
		}
		sum.ArchiveRacesAdded = current.Merge(*archive)
		// A partial overlap cannot be merged exactly from aggregates.
		sum.ArchiveSkipped = fresh > 0 && sum.ArchiveRacesAdded == 0
		if sum.ArchiveRacesAdded > 0 {
			if err := st.SaveDocument(ctx, archiveDocument, current, now); err != nil {
				return sum, err
			}
		}
	}

	if state != nil {
		sum.SamplesReceived = len(state.Samples)
		for _, sample := range state.Samples {
			added, err := st.InsertTrainingSample(ctx, sample, source)
			if err != nil {
				return sum, err
			}
			if added {
				sum.SamplesAdded++
			}
		}
		keys := make([]string, 0, len(state.PendingSnapshots))
		for k := range state.PendingSnapshots {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			added, err := st.InsertTrainingSample(ctx, training.Race{Snapshot: state.PendingSnapshots[k]}, source)
			if err != nil {
				return sum, err
			}
			if added {
				sum.PendingAdded++
			}
		}
		// Weights a phone promoted are kept so its tips stay attributable, but
		// not activated: the server's own training decides what runs.
		if w := state.ActiveWeights; w != nil && w.ID != "" {
			added, err := st.EnsureWeights(ctx, *w, "device", now)
			if err != nil {
				return sum, err
			}
			if added {
				sum.WeightsAdded = append(sum.WeightsAdded, w.ID)
			}
		}
	}

	raw, _ := json.Marshal(up)
	if err := st.SaveImport(ctx, up.Device, sum, raw, now); err != nil {
		return sum, err
	}
	return sum, nil
}

// prefer says whether an incoming device tip should replace the stored one.
func prefer(incoming tracking.Tip, existing store.TipRow) bool {
	if existing.Source == "server" {
		return false
	}
	current := existing.Tip
	switch {
	case incoming.IsSealed() && !current.IsSealed():
		return true
	case !incoming.IsSealed() && current.IsSealed():
		return false
	case incoming.IsSealed() && current.IsSealed():
		if incoming.SealedAt.Before(current.SealedAt.Time) {
			return true
		}
		if incoming.SealedAt.Equal(current.SealedAt.Time) {
			// Identical seal: the same tip re-uploaded. Only take it if it
			// knows an outcome the stored copy does not.
			return current.Outcome == nil && incoming.Outcome != nil
		}
		return false
	}
	// Two drafts: the later one, as the ledger itself would have kept; or the
	// same one again, if only the incoming copy knows how it turned out.
	if incoming.CreatedAt.Equal(current.CreatedAt.Time) {
		return current.Outcome == nil && incoming.Outcome != nil
	}
	return incoming.CreatedAt.After(current.CreatedAt.Time)
}
