package service

import (
	"context"

	"github.com/bensuskins/races/server/internal/importer"
)

// ImportHistory merges the historical documents from a device.
func (s *Service) ImportHistory(ctx context.Context, upload importer.Upload) (importer.Summary, error) {
	return importer.Import(ctx, s.ports.Imports, upload, s.Now())
}
