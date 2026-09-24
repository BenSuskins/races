package tracking

import (
	"time"

	"github.com/bensuskins/races/server/internal/domain"
)

const (
	// ExpiryDays is how long to keep looking for a result before giving up.
	// The server polls the today-only endpoint all day, so a tip that reaches
	// this is one whose result the provider genuinely never published.
	ExpiryDays = 7
	// MaximumAttempts before an unresolved tip expires.
	MaximumAttempts = 10
)

// Settle turns a result into an outcome. Pure: every awkward case has a test.
func Settle(tip Tip, result *domain.RaceResult, betfairSPs map[string]float64, meetingAbandoned bool, now time.Time) Tip {
	settled := tip
	if meetingAbandoned {
		settled.Outcome = &Outcome{Kind: Abandoned}
		return settled
	}
	if result == nil {
		settled.Outcome = giveUpOrKeepTrying(tip, now)
		return settled
	}

	ran, ok := result.DidRun(tip.SelectionHorseID)
	switch {
	case !ok:
		// A suspiciously short field settles nothing.
		settled.Outcome = giveUpOrKeepTrying(tip, now)
	case !ran:
		settled.Outcome = &Outcome{Kind: NonRunner}
	default:
		f := result.Finisher(tip.SelectionHorseID)
		sp := startingPrice(betfairSPs, tip.SelectionHorseID, f)
		if f != nil && f.Position.IsWinner() {
			settled.Outcome = &Outcome{Kind: Won, BetfairSP: sp}
		} else {
			var position *int
			if f != nil {
				position = f.Position.NumericPosition()
			}
			settled.Outcome = &Outcome{Kind: Lost, Position: position, BetfairSP: sp}
		}
	}
	if fav := favouriteOutcome(tip, *result, betfairSPs); fav != nil {
		settled.FavouriteOutcome = fav
	}
	return settled
}

func startingPrice(betfair map[string]float64, horseID string, f *domain.Finisher) *float64 {
	if p, ok := betfair[horseID]; ok {
		return &p
	}
	if f != nil {
		return f.StartingPriceDecimal
	}
	return nil
}

// favouriteOutcome is nil when the favourite did not run: a non-running
// favourite is not a losing favourite.
func favouriteOutcome(tip Tip, result domain.RaceResult, betfair map[string]float64) *FavouriteOutcome {
	if tip.MarketFavouriteHorseID == nil {
		return nil
	}
	id := *tip.MarketFavouriteHorseID
	if ran, ok := result.DidRun(id); !ok || !ran {
		return nil
	}
	f := result.Finisher(id)
	return &FavouriteOutcome{HorseID: id, Won: f != nil && f.Position.IsWinner(), BetfairSP: startingPrice(betfair, id, f)}
}

func giveUpOrKeepTrying(tip Tip, now time.Time) *Outcome {
	attempts := 1
	if tip.Outcome != nil && tip.Outcome.Kind == Unresolved {
		attempts = tip.Outcome.Attempts + 1
	}
	tooOld := tip.OffAt != nil && now.After(tip.OffAt.Add(ExpiryDays*24*time.Hour))
	if tooOld || attempts >= MaximumAttempts {
		return &Outcome{Kind: Expired, At: domain.At(now)}
	}
	return &Outcome{Kind: Unresolved, LastCheckedAt: domain.At(now), Attempts: attempts}
}
