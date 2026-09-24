package domain

import (
	"strconv"
	"strings"
	"time"
)

// London is the zone a racing day belongs to.
//
// A racing day is a Europe/London day, not a UTC one. Through British Summer
// Time the two disagree for an hour either side of midnight, which is enough to
// put an evening meeting on the wrong date or reconcile a tip against the next
// day's results. Every day string is produced here and nowhere else.
var London = mustLoad("Europe/London")

func mustLoad(name string) *time.Location {
	loc, err := time.LoadLocation(name)
	if err != nil {
		panic("load " + name + ": " + err.Error() + " (is tzdata embedded?)")
	}
	return loc
}

// RaceDay is which of the two days the free tier covers.
type RaceDay string

const (
	Today    RaceDay = "today"
	Tomorrow RaceDay = "tomorrow"
)

// ParseRaceDay accepts "today" and "tomorrow"; anything else is false.
func ParseRaceDay(raw string) (RaceDay, bool) {
	switch RaceDay(raw) {
	case Today, Tomorrow:
		return RaceDay(raw), true
	}
	return "", false
}

// DayString is yyyy-MM-dd in London for an instant.
func DayString(t time.Time) string {
	return t.In(London).Format("2006-01-02")
}

// DayStringFor is the London date of today or tomorrow relative to now.
func DayStringFor(day RaceDay, now time.Time) string {
	if day == Tomorrow {
		l := now.In(London)
		return time.Date(l.Year(), l.Month(), l.Day()+1, 12, 0, 0, 0, London).Format("2006-01-02")
	}
	return DayString(now)
}

// DayMatching says which provider day a date string is, if either.
func DayMatching(day string, now time.Time) (RaceDay, bool) {
	switch day {
	case DayStringFor(Today, now):
		return Today, true
	case DayStringFor(Tomorrow, now):
		return Tomorrow, true
	}
	return "", false
}

// DayWindow is [start, end) of a London day, as UTC instants.
func DayWindow(day string) (time.Time, time.Time, bool) {
	start, err := time.ParseInLocation("2006-01-02", day, London)
	if err != nil {
		return time.Time{}, time.Time{}, false
	}
	end := time.Date(start.Year(), start.Month(), start.Day()+1, 0, 0, 0, 0, London)
	return start, end, true
}

// ParseTimestamp reads a provider timestamp. Both providers send ISO-8601 but
// not always at the same precision, and the Racing API sometimes omits the
// zone — in which case London is right, since these are British off times.
func ParseTimestamp(raw string) (time.Time, bool) {
	if raw == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339, raw); err == nil {
		return t, true
	}
	for _, layout := range []string{"2006-01-02T15:04:05", "2006-01-02 15:04:05", "2006-01-02 15:04"} {
		if t, err := time.ParseInLocation(layout, raw, London); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

// Combine joins a yyyy-MM-dd date and an "H:mm" off time in London.
//
// British racecards print afternoon times in 12-hour form without a meridiem,
// so anything before 10:00 is read as PM.
func Combine(day, offTime string) (time.Time, bool) {
	pieces := strings.Split(offTime, ":")
	if len(pieces) < 2 {
		return time.Time{}, false
	}
	hour, err1 := strconv.Atoi(pieces[0])
	minute, err2 := strconv.Atoi(pieces[1])
	date, err3 := time.ParseInLocation("2006-01-02", day, London)
	if err1 != nil || err2 != nil || err3 != nil {
		return time.Time{}, false
	}
	if hour < 10 {
		hour += 12
	}
	return time.Date(date.Year(), date.Month(), date.Day(), min(hour, 23), min(minute, 59), 0, 0, London), true
}
