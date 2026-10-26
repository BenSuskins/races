package rating

import (
	"fmt"
	"math"
	"strings"

	"github.com/bensuskins/races/server/internal/domain"
)

type exchangeDepth struct{}

func (exchangeDepth) ID() FactorID { return ExchangeDepth }
func (exchangeDepth) Value(runner domain.Runner, context Context) FactorValue {
	market := context.Market
	if market == nil || market.Source != domain.SourceLiveExchange {
		return missing("no exchange depth")
	}
	if market.CapturedAt.After(context.Now) {
		return missing("exchange depth includes prices after the rating time")
	}
	price, found := market.Price(runner.ID)
	if !found || !price.IsActive {
		return missing("no active exchange runner")
	}
	if price.BackPrice == nil || price.LayPrice == nil || *price.BackPrice <= 1 || *price.LayPrice < *price.BackPrice {
		return missing("no valid two-sided exchange price")
	}
	if price.BackSize == nil || price.LaySize == nil || *price.BackSize <= 0 || *price.LaySize <= 0 || math.IsNaN(*price.BackSize) || math.IsNaN(*price.LaySize) || math.IsInf(*price.BackSize, 0) || math.IsInf(*price.LaySize, 0) {
		return missing("no positive two-sided exchange sizes")
	}
	depth := math.Min(*price.BackSize, *price.LaySize)
	return value(math.Log1p(depth), fmt.Sprintf("%.2f available on both sides of the best price", depth))
}

type horseSuitability struct{ factor FactorID }

func (factor horseSuitability) ID() FactorID { return factor.factor }
func (factor horseSuitability) Value(runner domain.Runner, context Context) FactorValue {
	provider, found := context.StrikeRates.(HorseConditionRates)
	if !found {
		return missing("no horse condition archive yet")
	}
	if context.Race.Surface == domain.SurfaceUnknown || context.Race.Surface == "" || context.Race.Type == domain.RaceTypeUnknown || context.Race.Type == "" {
		return missing("surface or race type is unknown")
	}
	if factor.factor == HorseCoursePlaceRate && context.Race.CourseName == "" {
		return missing("course is unknown")
	}
	if factor.factor == HorseDistancePlaceRate && (context.Race.Distance == nil || context.Race.Distance.Furlongs <= 0) {
		return missing("distance is unknown")
	}
	record, found := provider.HorseConditionRate(runner.ID, context.Race, factor.factor, context.Now)
	if !found || record.Runs < 3 {
		return missing(fmt.Sprintf("only %d completed comparable runs", record.Runs))
	}
	prior := fieldPlacePrior(context.Race.FieldSize)
	return value(record.Smoothed(prior, 5), fmt.Sprintf("%d places from %d comparable runs", record.Places, record.Runs))
}

type headgearChange struct{}

func (headgearChange) ID() FactorID { return HeadgearChange }
func (headgearChange) Value(runner domain.Runner, context Context) FactorValue {
	if !runner.HeadgearKnown && runner.Headgear == nil {
		return missing("current headgear is unknown")
	}
	provider, found := context.StrikeRates.(HeadgearHistory)
	if !found {
		return missing("no confirmed headgear history")
	}
	previous, found := provider.PreviousHeadgear(runner.ID, context.Race.ID, context.Now)
	if !found {
		return missing("no unique confirmed previous headgear")
	}
	current := ""
	if runner.Headgear != nil {
		current = strings.ToLower(strings.TrimSpace(*runner.Headgear))
	}
	if current == previous {
		return value(0, "Same headgear as the last observed run")
	}
	return value(1, "Headgear changed since the last observed run")
}

type pedigreeSuitability struct{ damsire bool }

func (factor pedigreeSuitability) ID() FactorID {
	if factor.damsire {
		return DamsireSuitability
	}
	return SireSuitability
}
func (factor pedigreeSuitability) Value(runner domain.Runner, context Context) FactorValue {
	parent := runner.SireID
	if factor.damsire {
		parent = runner.DamsireID
	}
	if parent == nil || *parent == "" {
		return missing("pedigree ID is unknown")
	}
	if context.Race.Distance == nil || context.Race.Distance.Furlongs <= 0 || context.Race.Going.Bucket(context.Race.Surface) == "" || context.Race.Type == domain.RaceTypeUnknown || context.Race.Type == "" {
		return missing("pedigree race conditions are unknown")
	}
	provider, found := context.StrikeRates.(PedigreeRates)
	if !found {
		return missing("no offspring archive yet")
	}
	record, found := provider.PedigreePlaceRate(*parent, factor.damsire, context.Race, context.Now)
	if !found || record.Runs < 30 {
		return missing(fmt.Sprintf("only %d comparable offspring runs", record.Runs))
	}
	return value(record.Smoothed(fieldPlacePrior(context.Race.FieldSize), 20), fmt.Sprintf("%d places from %d comparable offspring runs", record.Places, record.Runs))
}
