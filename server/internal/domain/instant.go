// Package domain holds the provider-agnostic types every other package shares.
//
// Their JSON is deliberately the shape Swift's synthesised Codable produces for
// the matching types in RacesKit: camelCase keys, optionals omitted, enums with
// associated values as single-key objects, dates as whole-second ISO-8601. That
// is what lets the app decode server responses with the models it already has,
// and what lets the server read the JSON documents a device uploads.
package domain

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"
)

// Instant is a point in time that encodes the way Swift's `.iso8601` date
// strategy does: UTC, whole seconds, no fraction.
//
// The fraction is the reason this type exists. Go's time.Time marshals
// RFC3339Nano, and Swift's `.iso8601` decoder rejects a fractional second
// outright — one sub-second timestamp would make the app discard the whole
// response.
type Instant struct{ time.Time }

// At wraps a time.Time.
func At(t time.Time) Instant { return Instant{t.UTC().Truncate(time.Second)} }

// Ptr returns a pointer to an Instant, for optional fields.
func Ptr(t time.Time) *Instant {
	i := At(t)
	return &i
}

func (i Instant) MarshalJSON() ([]byte, error) {
	return []byte(`"` + i.UTC().Truncate(time.Second).Format(time.RFC3339) + `"`), nil
}

func (i *Instant) UnmarshalJSON(data []byte) error {
	if bytes.Equal(data, []byte("null")) {
		return nil
	}
	var raw string
	if err := json.Unmarshal(data, &raw); err != nil {
		return fmt.Errorf("instant: %w", err)
	}
	t, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return fmt.Errorf("instant: %w", err)
	}
	i.Time = t.UTC()
	return nil
}
