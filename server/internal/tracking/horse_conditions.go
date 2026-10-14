package tracking

import (
	"strings"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
)

type ObservedHorseRun struct {
	SireID        *string               `json:"sireID,omitempty"`
	DamsireID     *string               `json:"damsireID,omitempty"`
	Headgear      *string               `json:"headgear,omitempty"`
	HeadgearKnown bool                  `json:"headgearKnown,omitempty"`
	RaceID        string                `json:"raceID"`
	OccurredAt    domain.Instant        `json:"occurredAt"`
	CourseName    string                `json:"courseName"`
	Surface       domain.Surface        `json:"surface"`
	RaceType      domain.RaceType       `json:"raceType"`
	Distance      *domain.Distance      `json:"distance,omitempty"`
	Going         domain.Going          `json:"going"`
	Position      domain.FinishPosition `json:"position"`
}

func (archive *Archive) observeHorse(result domain.RaceResult, finisher domain.Finisher) {
	occurred, err := time.ParseInLocation("2006-01-02", result.Date, domain.London)
	if err != nil || finisher.HorseID == "" {
		return
	}
	switch finisher.Position.Kind {
	case domain.PositionFinished:
		if finisher.Position.Position < 1 {
			return
		}
	case domain.PositionPulledUp, domain.PositionUnseatedRider, domain.PositionFell, domain.PositionRefused, domain.PositionBroughtDown, domain.PositionSlippedUp, domain.PositionDisqualified:
	default:
		return
	}
	if result.OffDateTime != nil {
		occurred = result.OffDateTime.Time
	}
	archive.HorseRuns[finisher.HorseID] = append(archive.HorseRuns[finisher.HorseID], ObservedHorseRun{SireID: finisher.SireID, DamsireID: finisher.DamsireID, Headgear: finisher.Headgear, HeadgearKnown: finisher.HeadgearKnown || finisher.Headgear != nil, RaceID: result.ID, OccurredAt: domain.At(occurred), CourseName: result.CourseName, Surface: result.Surface, RaceType: result.Type, Distance: result.Distance, Going: result.Going, Position: finisher.Position})
}

func distanceBand(distance *domain.Distance) string {
	if distance == nil || distance.Furlongs <= 0 {
		return ""
	}
	switch {
	case distance.Furlongs < 7:
		return "sprint"
	case distance.Furlongs < 9:
		return "mile"
	case distance.Furlongs < 13:
		return "middle"
	case distance.Furlongs < 20:
		return "staying"
	case distance.Furlongs < 24:
		return "jumps-middle"
	default:
		return "jumps-long"
	}
}

func (archive *Archive) HorseConditionRate(horseID string, race domain.Race, factor rating.FactorID, before time.Time) (rating.PlaceRate, bool) {
	archive.index()
	var record rating.PlaceRate
	for _, run := range archive.HorseRuns[horseID] {
		if run.RaceID == race.ID || !run.OccurredAt.Before(before) || run.Position.Kind != domain.PositionFinished || run.Position.Position < 1 || run.Surface != race.Surface || run.RaceType != race.Type {
			continue
		}
		switch factor {
		case rating.HorseCoursePlaceRate:
			if strings.TrimSpace(race.CourseName) == "" || !strings.EqualFold(strings.TrimSpace(run.CourseName), strings.TrimSpace(race.CourseName)) {
				continue
			}
		case rating.HorseDistancePlaceRate:
			if distanceBand(run.Distance) == "" || distanceBand(run.Distance) != distanceBand(race.Distance) {
				continue
			}
		case rating.HorseSurfacePlaceRate:
		default:
			continue
		}
		record.Runs++
		if run.Position.Position > 0 && run.Position.Position <= 3 {
			record.Places++
		}
	}
	return record, record.Runs > 0
}

func (archive *Archive) PreviousHeadgear(horseID string, raceID string, before time.Time) (string, bool) {
	archive.index()
	var latest *ObservedHorseRun
	ambiguous := false
	for _, run := range archive.HorseRuns[horseID] {
		if run.RaceID == raceID || !run.OccurredAt.Before(before) {
			continue
		}
		if latest == nil || latest.OccurredAt.Before(run.OccurredAt.Time) {
			copy := run
			latest = &copy
			ambiguous = false
		} else if latest.OccurredAt.Equal(run.OccurredAt.Time) {
			ambiguous = true
		}
	}
	if latest == nil || !latest.HeadgearKnown || ambiguous {
		return "", false
	}
	if latest.Headgear == nil {
		return "", true
	}
	return strings.ToLower(strings.TrimSpace(*latest.Headgear)), true
}

func (archive *Archive) PedigreePlaceRate(parentID string, damsire bool, race domain.Race, before time.Time) (rating.PlaceRate, bool) {
	archive.index()
	var record rating.PlaceRate
	band := distanceBand(race.Distance)
	going := race.Going.Bucket(race.Surface)
	if parentID == "" || band == "" || going == "" {
		return record, false
	}
	for _, runs := range archive.HorseRuns {
		for _, run := range runs {
			parent := run.SireID
			if damsire {
				parent = run.DamsireID
			}
			if parent == nil || *parent != parentID || run.RaceID == race.ID || !run.OccurredAt.Before(before) || run.Position.Kind != domain.PositionFinished || run.Position.Position < 1 || run.Surface != race.Surface || run.RaceType != race.Type || distanceBand(run.Distance) != band || run.Going.Bucket(run.Surface) != going {
				continue
			}
			record.Runs++
			if run.Position.Position > 0 && run.Position.Position <= 3 {
				record.Places++
			}
		}
	}
	return record, record.Runs > 0
}

func (archive *Archive) RebuildHorseHistory(results []domain.RaceResult) {
	archive.HorseRuns = map[string][]ObservedHorseRun{}
	for _, result := range results {
		for _, finisher := range result.Finishers {
			archive.observeHorse(result, finisher)
		}
	}
}
