package matching

import (
	"encoding/json"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
)

// Record preserves a market match or the reason matching was refused.
type Record struct {
	RaceID    string                  `json:"raceID"`
	MarketID  string                  `json:"marketID,omitempty"`
	MatchedAt time.Time               `json:"-"`
	Reference *domain.MarketReference `json:"reference,omitempty"`
	Refusal   json.RawMessage         `json:"refusal,omitempty"`
}
