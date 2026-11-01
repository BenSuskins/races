package wiring

import (
	"context"

	"github.com/bensuskins/races/server/internal/importer"
	"github.com/bensuskins/races/server/internal/service"
	"github.com/bensuskins/races/server/internal/store"
)

type importStore struct{ *store.Store }

func (r importStore) ImportTransaction(ctx context.Context, run func(importer.Transaction) error) error {
	return r.Store.Tx(ctx, func(transaction *store.Tx) error { return run(transaction) })
}

// Storage connects the SQLite adapter to the application ports.
func Storage(st *store.Store) service.Persistence {
	return service.Persistence{Imports: importStore{st}, Weights: st, Jobs: st, Cards: st, Markets: st, Tips: st, Results: st, Training: st, Documents: st, History: st, Assessments: st}
}
