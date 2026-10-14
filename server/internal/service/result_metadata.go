package service

import "github.com/bensuskins/races/server/internal/domain"

func resultWithCardMetadata(result domain.RaceResult, card domain.Race) domain.RaceResult {
	if result.ID != card.ID {
		return result
	}
	result.Finishers = append([]domain.Finisher(nil), result.Finishers...)
	runners := map[string]domain.Runner{}
	for _, runner := range card.Runners {
		runners[runner.ID] = runner
	}
	for index, finisher := range result.Finishers {
		runner, found := runners[finisher.HorseID]
		if !found {
			continue
		}
		if finisher.SireID == nil {
			finisher.SireID = runner.SireID
		}
		if finisher.DamsireID == nil {
			finisher.DamsireID = runner.DamsireID
		}
		if !finisher.HeadgearKnown && finisher.Headgear == nil && (runner.HeadgearKnown || runner.Headgear != nil) {
			finisher.Headgear = runner.Headgear
			finisher.HeadgearKnown = true
		}
		result.Finishers[index] = finisher
	}
	return result
}
