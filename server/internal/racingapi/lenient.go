package racingapi

import (
	"bytes"
	"encoding/json"
	"math"
	"strconv"
	"strings"
)

// Number is a numeric field the provider may send as 7, "7.0", "", "-" or
// null. Its own spec declares ofr, lbs, draw, number and last_run as strings,
// and they arrive both quoted and bare. Anything unreadable is unknown — never
// zero, which would make an unrated horse the worst in the race.
type Number struct {
	Value *float64
}

var placeholders = map[string]bool{"-": true, "–": true, "—": true, "n/a": true, "na": true, "null": true, "nil": true, "nr": true, "?": true}

func (n *Number) UnmarshalJSON(data []byte) error {
	n.Value = nil
	trimmed := bytes.TrimSpace(data)
	if bytes.Equal(trimmed, []byte("null")) {
		return nil
	}
	var f float64
	if err := json.Unmarshal(trimmed, &f); err == nil {
		n.Value = &f
		return nil
	}
	var s string
	if err := json.Unmarshal(trimmed, &s); err == nil {
		s = strings.TrimSpace(s)
		if s == "" || placeholders[strings.ToLower(s)] {
			return nil
		}
		if f, err := strconv.ParseFloat(s, 64); err == nil {
			n.Value = &f
		}
	}
	// Any other shape is unknown rather than a failed card.
	return nil
}

// Int rounds to the nearest whole number, or nil.
func (n *Number) Int() *int {
	if n == nil || n.Value == nil || math.IsInf(*n.Value, 0) || math.IsNaN(*n.Value) {
		return nil
	}
	v := int(math.Round(*n.Value))
	return &v
}

func (n *Number) Float() *float64 {
	if n == nil {
		return nil
	}
	return n.Value
}

// Text is a text field the provider may send as a number. position holds "PU"
// and "F" over jumps and also arrives as a bare 1; one unquoted value must not
// throw away the race.
type Text struct {
	Value *string
}

func (t *Text) UnmarshalJSON(data []byte) error {
	t.Value = nil
	trimmed := bytes.TrimSpace(data)
	var s string
	if err := json.Unmarshal(trimmed, &s); err == nil {
		t.set(s)
		return nil
	}
	var f float64
	if err := json.Unmarshal(trimmed, &f); err == nil {
		if f == math.Trunc(f) {
			t.set(strconv.FormatInt(int64(f), 10))
		} else {
			t.set(strconv.FormatFloat(f, 'f', -1, 64))
		}
	}
	return nil
}

func (t *Text) set(s string) {
	s = strings.TrimSpace(s)
	if s != "" {
		t.Value = &s
	}
}

// NonEmpty is a trimmed value, or nil when blank or a "-" placeholder.
func (t *Text) NonEmpty() *string {
	if t == nil || t.Value == nil || *t.Value == "-" {
		return nil
	}
	v := *t.Value
	return &v
}

// Or returns the value or a fallback.
func (t *Text) Or(fallback string) string {
	if v := t.NonEmpty(); v != nil {
		return *v
	}
	return fallback
}
