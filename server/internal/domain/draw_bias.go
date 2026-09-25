package domain

import (
	"fmt"
	"math"
	"strings"
)

// DrawBiasCellKey identifies a broad course, distance, ground, field-size, and draw context.
func DrawBiasCellKey(courseName string, distance *Distance, surface Surface, going Going, fieldSize, draw int) (string, bool) {
	if strings.TrimSpace(courseName) == "" || distance == nil || distance.Furlongs <= 0 || math.IsNaN(distance.Furlongs) || math.IsInf(distance.Furlongs, 0) || fieldSize < 5 || draw < 1 || draw > fieldSize {
		return "", false
	}
	ground := going.Bucket(surface)
	if ground == "" {
		return "", false
	}
	distanceBand := "staying"
	switch {
	case distance.Furlongs <= 6:
		distanceBand = "sprint"
	case distance.Furlongs <= 8:
		distanceBand = "mile"
	case distance.Furlongs <= 12:
		distanceBand = "middle"
	}
	fieldBand := "17+"
	switch {
	case fieldSize <= 8:
		fieldBand = "5-8"
	case fieldSize <= 12:
		fieldBand = "9-12"
	case fieldSize <= 16:
		fieldBand = "13-16"
	}
	drawBand := "outside"
	if draw*3 <= fieldSize {
		drawBand = "inside"
	} else if draw*3 <= fieldSize*2 {
		drawBand = "middle"
	}
	return fmt.Sprintf("%s|%s|%s|%s|%s|%s", strings.ToLower(strings.TrimSpace(courseName)), surface, distanceBand, ground, fieldBand, drawBand), true
}
