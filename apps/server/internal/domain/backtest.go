package domain

import (
	"encoding/json"
)

// StoredReport is a saved back-test request and its result.
type StoredBacktest struct {
	ID        int64           `json:"id"`
	CreatedAt Instant         `json:"createdAt"`
	WeightsID string          `json:"weightsID"`
	Request   json.RawMessage `json:"request"`
	Report    json.RawMessage `json:"report"`
}
