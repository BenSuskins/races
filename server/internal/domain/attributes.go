package domain

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"

	_ "time/tzdata" // the image is distroless; London must resolve without /usr/share/zoneinfo
)

// Going is the state of the ground. Raw values match Swift's enum cases.
type Going string

const (
	GoingHeavy          Going = "heavy"
	GoingSoft           Going = "soft"
	GoingGoodToSoft     Going = "goodToSoft"
	GoingGood           Going = "good"
	GoingGoodToFirm     Going = "goodToFirm"
	GoingFirm           Going = "firm"
	GoingSlow           Going = "slow"
	GoingStandardToSlow Going = "standardToSlow"
	GoingStandard       Going = "standard"
	GoingStandardToFast Going = "standardToFast"
	GoingFast           Going = "fast"
	GoingUnknown        Going = "unknown"
)

// ParseGoing maps a provider string; anything unrecognised is unknown rather
// than an error, because a novel description must not cost us the card.
func ParseGoing(raw string) Going {
	key := strings.NewReplacer(" ", "", "-", "").Replace(strings.ToLower(raw))
	switch key {
	case "heavy":
		return GoingHeavy
	case "soft":
		return GoingSoft
	case "goodtosoft", "gdsft", "goodtosoftgoodinplaces":
		return GoingGoodToSoft
	case "good", "gd":
		return GoingGood
	case "goodtofirm", "gdfm":
		return GoingGoodToFirm
	case "firm", "fm", "hard":
		return GoingFirm
	case "slow":
		return GoingSlow
	case "standardtoslow":
		return GoingStandardToSlow
	case "standard", "std":
		return GoingStandard
	case "standardtofast":
		return GoingStandardToFast
	case "fast":
		return GoingFast
	}
	return GoingUnknown
}

// Surface is turf or all-weather.
type Surface string

const (
	SurfaceTurf       Surface = "turf"
	SurfaceAllWeather Surface = "allWeather"
	SurfaceUnknown    Surface = "unknown"
)

func ParseSurface(raw string) Surface {
	switch strings.ReplaceAll(strings.ToLower(raw), " ", "") {
	case "turf", "grass":
		return SurfaceTurf
	case "aw", "allweather", "polytrack", "tapeta", "fibresand", "dirt", "sand":
		return SurfaceAllWeather
	}
	return SurfaceUnknown
}

// RaceType is the code of racing.
type RaceType string

const (
	RaceTypeFlat             RaceType = "flat"
	RaceTypeHurdle           RaceType = "hurdle"
	RaceTypeChase            RaceType = "chase"
	RaceTypeNationalHuntFlat RaceType = "nationalHuntFlat"
	RaceTypeUnknown          RaceType = "unknown"
)

func ParseRaceType(raw string) RaceType {
	switch strings.ReplaceAll(strings.ToLower(raw), " ", "") {
	case "flat":
		return RaceTypeFlat
	case "hurdle", "hurdles":
		return RaceTypeHurdle
	case "chase", "chases", "steeplechase":
		return RaceTypeChase
	case "nhflat", "nationalhuntflat", "bumper", "inhflat":
		return RaceTypeNationalHuntFlat
	}
	return RaceTypeUnknown
}

// IsJumps is whether runners jump obstacles. A bumper has none.
func (t RaceType) IsJumps() bool { return t == RaceTypeHurdle || t == RaceTypeChase }

// Distance is a race distance in furlongs. Encodes as {"furlongs": n}, as the
// Swift struct does.
type Distance struct {
	Furlongs float64 `json:"furlongs"`
}

// NewDistance returns nil for a missing, non-positive or non-finite value.
func NewDistance(furlongs *float64) *Distance {
	if furlongs == nil || *furlongs <= 0 || math.IsInf(*furlongs, 0) || math.IsNaN(*furlongs) {
		return nil
	}
	return &Distance{Furlongs: *furlongs}
}

// ClosedRange is Swift's ClosedRange<Int>, which Codable writes as [lower, upper].
type ClosedRange struct {
	Lower, Upper int
}

func (r ClosedRange) MarshalJSON() ([]byte, error) {
	return json.Marshal([2]int{r.Lower, r.Upper})
}

func (r *ClosedRange) UnmarshalJSON(data []byte) error {
	var pair []int
	if err := json.Unmarshal(data, &pair); err != nil {
		return err
	}
	if len(pair) != 2 {
		return fmt.Errorf("closed range: want 2 bounds, got %d", len(pair))
	}
	r.Lower, r.Upper = pair[0], pair[1]
	return nil
}

// FinishPosition is how a horse finished, or failed to.
//
// Swift encodes it as a single-key object: {"finished":{"_0":3}},
// {"pulledUp":{}}, {"other":{"_0":"WTF"}}. Kind holds the case name.
type FinishPosition struct {
	Kind     string
	Position int    // finished only
	Raw      string // other only
}

const (
	PositionFinished      = "finished"
	PositionPulledUp      = "pulledUp"
	PositionUnseatedRider = "unseatedRider"
	PositionFell          = "fell"
	PositionRefused       = "refused"
	PositionBroughtDown   = "broughtDown"
	PositionSlippedUp     = "slippedUp"
	PositionDisqualified  = "disqualified"
	PositionVoided        = "voided"
	PositionOther         = "other"
)

func Finished(n int) FinishPosition { return FinishPosition{Kind: PositionFinished, Position: n} }

// ParseFinishPosition reads the provider's position string.
func ParseFinishPosition(raw *string) FinishPosition {
	if raw == nil {
		return FinishPosition{Kind: PositionOther}
	}
	key := strings.ToUpper(strings.TrimSpace(*raw))
	if n, err := strconv.Atoi(key); err == nil && n > 0 {
		return Finished(n)
	}
	switch key {
	case "PU", "P":
		return FinishPosition{Kind: PositionPulledUp}
	case "UR", "U":
		return FinishPosition{Kind: PositionUnseatedRider}
	case "F":
		return FinishPosition{Kind: PositionFell}
	case "REF", "R":
		return FinishPosition{Kind: PositionRefused}
	case "BD", "B":
		return FinishPosition{Kind: PositionBroughtDown}
	case "SU", "S":
		return FinishPosition{Kind: PositionSlippedUp}
	case "DSQ", "DQ", "D":
		return FinishPosition{Kind: PositionDisqualified}
	case "VOI", "V":
		return FinishPosition{Kind: PositionVoided}
	}
	return FinishPosition{Kind: PositionOther, Raw: key}
}

func (p FinishPosition) IsWinner() bool    { return p.Kind == PositionFinished && p.Position == 1 }
func (p FinishPosition) DidComplete() bool { return p.Kind == PositionFinished }

// NumericPosition is the place, or nil if the horse did not complete.
func (p FinishPosition) NumericPosition() *int {
	if p.Kind != PositionFinished {
		return nil
	}
	n := p.Position
	return &n
}

func (p FinishPosition) MarshalJSON() ([]byte, error) {
	switch p.Kind {
	case PositionFinished:
		return json.Marshal(map[string]map[string]int{p.Kind: {"_0": p.Position}})
	case PositionOther:
		return json.Marshal(map[string]map[string]string{p.Kind: {"_0": p.Raw}})
	case "":
		return json.Marshal(map[string]map[string]string{PositionOther: {"_0": ""}})
	}
	return json.Marshal(map[string]struct{}{p.Kind: {}})
}

func (p *FinishPosition) UnmarshalJSON(data []byte) error {
	var wrapper map[string]json.RawMessage
	if err := json.Unmarshal(data, &wrapper); err != nil {
		return err
	}
	for kind, body := range wrapper {
		p.Kind = kind
		switch kind {
		case PositionFinished:
			var v struct {
				N int `json:"_0"`
			}
			if err := json.Unmarshal(body, &v); err != nil {
				return err
			}
			p.Position = v.N
		case PositionOther:
			var v struct {
				S string `json:"_0"`
			}
			if err := json.Unmarshal(body, &v); err != nil {
				return err
			}
			p.Raw = v.S
		}
		return nil
	}
	return fmt.Errorf("finish position: empty object")
}
