// Package matching joins the Racing API's view of a race to Betfair's.
//
// It refuses rather than guesses: a race with no market falls back to form and
// says so, while a race with the wrong market silently anchors every runner to
// another race's prices and looks entirely normal. See docs/matching.md.
package matching

import (
	"strings"
	"unicode"
)

var droppableSuffixes = map[string]bool{
	"park": true, "downs": true, "bridge": true, "city": true, "racecourse": true, "racetrack": true, "races": true,
}

// Deliberately not "royal": Down Royal is a course in its own right.
var droppablePrefixes = map[string]bool{"the": true, "great": true}

// CourseKey reduces a course name to a comparison key, removing only words no
// British or Irish course needs to be identified. TestNoTwoRealCoursesShareAKey
// is the safety net; no rule is acceptable unless it still passes.
func CourseKey(raw string) string {
	text := stripParentheticals(strings.ToLower(raw))
	text = strings.ReplaceAll(text, "-", " ")
	words := strings.FieldsFunc(text, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) })

	for i, w := range words {
		if w == "on" && i > 0 {
			words = words[:i]
			break
		}
	}
	for len(words) > 1 && droppablePrefixes[words[0]] {
		words = words[1:]
	}
	for len(words) > 1 && droppableSuffixes[words[len(words)-1]] {
		words = words[:len(words)-1]
	}
	return strings.Join(words, " ")
}

// CoursesMatch is true when two names describe the same course. An empty key
// never matches, or every unnamed course would match every other.
func CoursesMatch(a, b string) bool {
	k := CourseKey(a)
	return k != "" && k == CourseKey(b)
}

func stripParentheticals(text string) string {
	var b strings.Builder
	depth := 0
	for _, c := range text {
		switch c {
		case '(', '[':
			depth++
		case ')', ']':
			depth = max(0, depth-1)
		default:
			if depth == 0 {
				b.WriteRune(c)
			}
		}
	}
	return b.String()
}

// HorseKey is uppercase letters and digits only, after Betfair's cloth prefix
// ("3. Kyprios") and country suffix ("Kyprios (IRE)") come off.
func HorseKey(raw string) string {
	text := stripCountrySuffix(stripClothPrefix(raw))
	var b strings.Builder
	for _, c := range strings.ToUpper(text) {
		if unicode.IsLetter(c) || unicode.IsNumber(c) {
			b.WriteRune(c)
		}
	}
	return b.String()
}

func stripClothPrefix(text string) string {
	trimmed := []rune(strings.TrimSpace(text))
	i := 0
	for i < len(trimmed) && unicode.IsNumber(trimmed[i]) {
		i++
	}
	if i == 0 || i >= len(trimmed) {
		return string(trimmed)
	}
	// The separator is what tells a cloth prefix from a name starting with a
	// numeral.
	switch {
	case trimmed[i] == '.' || trimmed[i] == ')':
		i++
	case !unicode.IsSpace(trimmed[i]):
		return string(trimmed)
	}
	rest := strings.TrimSpace(string(trimmed[i:]))
	if rest == "" {
		return string(trimmed)
	}
	return rest
}

func stripCountrySuffix(text string) string {
	trimmed := strings.TrimSpace(text)
	if !strings.HasSuffix(trimmed, ")") {
		return trimmed
	}
	open := strings.LastIndex(trimmed, "(")
	if open < 0 {
		return trimmed
	}
	inside := []rune(trimmed[open+1 : len(trimmed)-1])
	if len(inside) < 2 || len(inside) > 3 {
		return trimmed
	}
	for _, c := range inside {
		if !unicode.IsLetter(c) {
			return trimmed
		}
	}
	rest := strings.TrimSpace(trimmed[:open])
	if rest == "" {
		return trimmed
	}
	return rest
}

// NameDistance is Levenshtein distance, or -1 once it cannot be within limit.
func NameDistance(a, b string, limit int) int {
	l, r := []rune(a), []rune(b)
	if string(l) == string(r) {
		return 0
	}
	if abs(len(l)-len(r)) > limit {
		return -1
	}
	if len(l) == 0 {
		return within(len(r), limit)
	}
	if len(r) == 0 {
		return within(len(l), limit)
	}
	prev := make([]int, len(r)+1)
	cur := make([]int, len(r)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(l); i++ {
		cur[0] = i
		best := cur[0]
		for j := 1; j <= len(r); j++ {
			sub := prev[j-1]
			if l[i-1] != r[j-1] {
				sub++
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, sub)
			best = min(best, cur[j])
		}
		if best > limit {
			return -1
		}
		prev, cur = cur, prev
	}
	return within(prev[len(r)], limit)
}

func within(d, limit int) int {
	if d <= limit {
		return d
	}
	return -1
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}
