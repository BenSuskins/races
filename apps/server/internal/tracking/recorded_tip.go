package tracking

// RecordedTip joins a tip to the origin of its record.
type RecordedTip struct {
	Tip    Tip
	Source string
}
