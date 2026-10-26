// Package tracking is the accuracy record: tips, the sealing rule, settlement
// against results, and the report that keeps the model honest.
package tracking

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/rating"
)

// Outcome is how a tip turned out. The JSON is Swift's synthesised enum shape:
// {"won":{"betfairSP":4.2}}, {"nonRunner":{}}, {"expired":{"at":"…"}}.
type Outcome struct {
	Kind          string
	BetfairSP     *float64       // won, lost
	Position      *int           // lost
	LastCheckedAt domain.Instant // unresolved
	Attempts      int            // unresolved
	At            domain.Instant // expired
}

const (
	Won        = "won"
	Lost       = "lost"
	NonRunner  = "nonRunner"
	Abandoned  = "abandoned"
	Unresolved = "unresolved"
	Expired    = "expired"
)

// IsSettled: only won and lost count toward strike rate and ROI.
func (o Outcome) IsSettled() bool { return o.Kind == Won || o.Kind == Lost }

// IsVoid: the race happened but our selection did not take part.
func (o Outcome) IsVoid() bool { return o.Kind == NonRunner || o.Kind == Abandoned }
func (o Outcome) IsWin() bool  { return o.Kind == Won }

func (o Outcome) MarshalJSON() ([]byte, error) {
	var body any
	switch o.Kind {
	case Won:
		body = struct {
			SP *float64 `json:"betfairSP,omitempty"`
		}{o.BetfairSP}
	case Lost:
		body = struct {
			Position *int     `json:"position,omitempty"`
			SP       *float64 `json:"betfairSP,omitempty"`
		}{o.Position, o.BetfairSP}
	case Unresolved:
		body = struct {
			LastCheckedAt domain.Instant `json:"lastCheckedAt"`
			Attempts      int            `json:"attempts"`
		}{o.LastCheckedAt, o.Attempts}
	case Expired:
		body = struct {
			At domain.Instant `json:"at"`
		}{o.At}
	case NonRunner, Abandoned:
		body = struct{}{}
	default:
		return nil, fmt.Errorf("outcome: unknown kind %q", o.Kind)
	}
	return json.Marshal(map[string]any{o.Kind: body})
}

func (o *Outcome) UnmarshalJSON(data []byte) error {
	var wrapper map[string]json.RawMessage
	if err := json.Unmarshal(data, &wrapper); err != nil {
		return err
	}
	for kind, body := range wrapper {
		var v struct {
			BetfairSP     *float64        `json:"betfairSP"`
			Position      *int            `json:"position"`
			LastCheckedAt *domain.Instant `json:"lastCheckedAt"`
			Attempts      int             `json:"attempts"`
			At            *domain.Instant `json:"at"`
		}
		if err := json.Unmarshal(body, &v); err != nil {
			return err
		}
		*o = Outcome{Kind: kind, BetfairSP: v.BetfairSP, Position: v.Position, Attempts: v.Attempts}
		if v.LastCheckedAt != nil {
			o.LastCheckedAt = *v.LastCheckedAt
		}
		if v.At != nil {
			o.At = *v.At
		}
		switch kind {
		case Won, Lost, NonRunner, Abandoned, Unresolved, Expired:
			return nil
		}
		return fmt.Errorf("outcome: unknown kind %q", kind)
	}
	return fmt.Errorf("outcome: empty object")
}

// FavouriteOutcome is what the market favourite did in the same race, captured
// at settlement because the free results endpoint will not have it tomorrow.
type FavouriteOutcome struct {
	HorseID   string   `json:"horseID"`
	Won       bool     `json:"won"`
	BetfairSP *float64 `json:"betfairSP,omitempty"`
}

// Tip is frozen at the moment it was made — model version and explanation
// included — because re-deriving it later would measure today's model against
// yesterday's races.
type Tip struct {
	RaceID                 string                  `json:"raceID"`
	RaceDate               string                  `json:"raceDate"`
	OffAt                  *domain.Instant         `json:"offAt,omitempty"`
	CourseName             string                  `json:"courseName"`
	RaceName               string                  `json:"raceName"`
	RaceType               domain.RaceType         `json:"raceType"`
	FieldSizeAtTip         int                     `json:"fieldSizeAtTip"`
	SelectionHorseID       string                  `json:"selectionHorseID"`
	SelectionHorseName     string                  `json:"selectionHorseName"`
	PredictedProbability   float64                 `json:"predictedProbability"`
	MarketProbabilityAtTip *float64                `json:"marketProbabilityAtTip,omitempty"`
	MarketBackPriceAtTip   *float64                `json:"marketBackPriceAtTip,omitempty"`
	MarketFavouriteHorseID *string                 `json:"marketFavouriteHorseID,omitempty"`
	AgreedWithFavourite    *bool                   `json:"agreedWithFavourite,omitempty"`
	WasFormOnly            bool                    `json:"wasFormOnly"`
	Confidence             rating.Confidence       `json:"confidence"`
	ModelVersion           string                  `json:"modelVersion"`
	WeightsID              string                  `json:"weightsID"`
	Contributions          []rating.Contribution   `json:"contributions"`
	MarketReference        *domain.MarketReference `json:"marketReference,omitempty"`
	CreatedAt              domain.Instant          `json:"createdAt"`
	SealedAt               *domain.Instant         `json:"sealedAt,omitempty"`
	Outcome                *Outcome                `json:"outcome,omitempty"`
	FavouriteOutcome       *FavouriteOutcome       `json:"favouriteOutcome,omitempty"`
}

func (t Tip) IsSealed() bool { return t.SealedAt != nil }

// NewTip builds a tip from a rated race, or false when there is no selection.
func NewTip(a rating.Assessment, race domain.Race, ref *domain.MarketReference, now time.Time) (Tip, bool) {
	sel := a.Selection()
	if sel == nil {
		return Tip{}, false
	}
	t := Tip{
		RaceID: a.RaceID, RaceDate: race.Date, OffAt: race.OffDateTime, CourseName: race.CourseName,
		RaceName: race.Name, RaceType: race.Type, FieldSizeAtTip: len(race.Runners),
		SelectionHorseID: sel.HorseID, SelectionHorseName: sel.HorseName,
		PredictedProbability: sel.WinProbability, MarketProbabilityAtTip: sel.MarketProbability,
		MarketBackPriceAtTip: sel.MarketBackPrice, AgreedWithFavourite: a.AgreesWithMarket(),
		WasFormOnly: a.IsFormOnly(), Confidence: a.Confidence, ModelVersion: a.ModelVersion,
		WeightsID: a.WeightsID, Contributions: sel.Contributions, MarketReference: ref,
		CreatedAt: domain.At(now),
	}
	if fav := a.MarketFavourite(); fav != nil {
		id := fav.HorseID
		t.MarketFavouriteHorseID = &id
	}
	if t.Contributions == nil {
		t.Contributions = []rating.Contribution{}
	}
	return t, true
}
