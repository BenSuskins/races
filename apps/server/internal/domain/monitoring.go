package domain

// JobRun describes the most recent attempt and success of a scheduled job.
type JobRun struct {
	Name        string   `json:"name"`
	StartedAt   *Instant `json:"startedAt,omitempty"`
	FinishedAt  *Instant `json:"finishedAt,omitempty"`
	SucceededAt *Instant `json:"succeededAt,omitempty"`
	Error       string   `json:"error,omitempty"`
	Summary     string   `json:"summary,omitempty"`
}

// Counts summarizes the durable records held by the service.
type Counts struct {
	Races, Results, Tips, SealedTips, SettledTips, Payloads, TrainingSettled, TrainingPending int
}
