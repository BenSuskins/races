package testutil

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
)

// CompareJSON compares JSON values while allowing small platform differences
// in floating-point calculations.
func CompareJSON(expected, actual []byte) (bool, error) {
	expectedValue, err := decodeJSON(expected)
	if err != nil {
		return false, fmt.Errorf("decode expected JSON: %w", err)
	}
	actualValue, err := decodeJSON(actual)
	if err != nil {
		return false, fmt.Errorf("decode actual JSON: %w", err)
	}
	return equalJSON(expectedValue, actualValue), nil
}

func decodeJSON(data []byte) (any, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	return value, nil
}

func equalJSON(expected, actual any) bool {
	switch expectedValue := expected.(type) {
	case map[string]any:
		actualValue, ok := actual.(map[string]any)
		if !ok || len(expectedValue) != len(actualValue) {
			return false
		}
		for key, value := range expectedValue {
			other, ok := actualValue[key]
			if !ok || !equalJSON(value, other) {
				return false
			}
		}
		return true
	case []any:
		actualValue, ok := actual.([]any)
		if !ok || len(expectedValue) != len(actualValue) {
			return false
		}
		for index, value := range expectedValue {
			if !equalJSON(value, actualValue[index]) {
				return false
			}
		}
		return true
	case json.Number:
		actualValue, ok := actual.(json.Number)
		if !ok {
			return false
		}
		if expectedInteger, expectedErr := strconv.ParseInt(expectedValue.String(), 10, 64); expectedErr == nil {
			if actualInteger, actualErr := strconv.ParseInt(actualValue.String(), 10, 64); actualErr == nil {
				return expectedInteger == actualInteger
			}
		}
		expectedNumber, expectedErr := expectedValue.Float64()
		actualNumber, actualErr := actualValue.Float64()
		if expectedErr != nil || actualErr != nil {
			return false
		}
		scale := math.Max(1, math.Max(math.Abs(expectedNumber), math.Abs(actualNumber)))
		return math.Abs(expectedNumber-actualNumber) <= 1e-12*scale
	default:
		return expected == actual
	}
}
