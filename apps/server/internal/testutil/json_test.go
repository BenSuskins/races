package testutil

import "testing"

func TestCompareJSON(t *testing.T) {
	tests := []struct {
		name     string
		expected string
		actual   string
		matches  bool
	}{
		{
			name:     "small floating point drift",
			expected: `{"value":0.1234567890123456}`,
			actual:   `{"value":0.1234567890123457}`,
			matches:  true,
		},
		{
			name:     "different integers",
			expected: `{"value":1}`,
			actual:   `{"value":2}`,
		},
		{
			name:     "different JSON structure",
			expected: `{"value":1}`,
			actual:   `{"other":1}`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			matches, err := CompareJSON([]byte(test.expected), []byte(test.actual))
			if err != nil {
				t.Fatal(err)
			}
			if matches != test.matches {
				t.Fatalf("CompareJSON() = %t, want %t", matches, test.matches)
			}
		})
	}
}
