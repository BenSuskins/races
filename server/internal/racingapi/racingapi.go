// Package racingapi is The Racing API client, written against the FREE tier.
//
// The endpoint names are inverted relative to the tiers: /v1/racecards/free
// returns the Basic schema and /v1/racecards/basic the full one. Read the tier
// column in docs/providers.md, not the path. Any change here must update
// docs/providers.md in the same commit.
package racingapi

import (
	"context"
	"errors"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/bensuskins/races/server/internal/domain"
	"github.com/bensuskins/races/server/internal/httpx"
)

const (
	ProductionBaseURL = "https://api.theracingapi.com"
	// FreeTierRPS is the free tier's published limit.
	FreeTierRPS = 1.0
)

// Client talks to The Racing API.
type Client struct {
	http     *httpx.Client
	username string
	password string

	mu                  sync.Mutex
	formHistoryRefused  bool
	formHistoryDetected bool
	now                 func() time.Time
}

func New(baseURL, username, password string, http *httpx.Client) *Client {
	if http == nil {
		http = httpx.New(baseURL, FreeTierRPS, nil)
	}
	return &Client{http: http, username: username, password: password, now: time.Now}
}

// HTTP exposes the pipeline, so the service can attach a payload recorder.
func (c *Client) HTTP() *httpx.Client { return c.http }

func (c *Client) configured() error {
	if strings.TrimSpace(c.username) == "" || strings.TrimSpace(c.password) == "" {
		return &httpx.Error{Kind: httpx.NotConfigured, Message: "The Racing API"}
	}
	return nil
}

func (c *Client) auth() httpx.Auth { return httpx.Basic(c.username, c.password) }

// Courses for the given regions.
func (c *Client) Courses(ctx context.Context, regions ...string) ([]domain.Course, error) {
	if err := c.configured(); err != nil {
		return nil, err
	}
	resp, err := c.http.Get(ctx, "/v1/courses", url.Values{"region_codes": regions}, c.auth())
	if err != nil {
		return nil, err
	}
	var page struct {
		Courses []courseDTO `json:"courses"`
	}
	if err := resp.Decode(&page); err != nil {
		return nil, err
	}
	var out []domain.Course
	for _, dto := range page.Courses {
		if course, ok := mapCourse(dto); ok {
			out = append(out, course)
		}
	}
	return out, nil
}

// Racecards for today or tomorrow.
func (c *Client) Racecards(ctx context.Context, day domain.RaceDay, regions ...string) ([]domain.Race, error) {
	if err := c.configured(); err != nil {
		return nil, err
	}
	resp, err := c.http.Get(ctx, "/v1/racecards/free", url.Values{"day": {string(day)}, "region_codes": regions}, c.auth())
	if err != nil {
		return nil, err
	}
	return ParseRacecards(resp.Body, c.now())
}

// ParseRacecards decodes a racecards page; exported for the fixture tests and
// for re-parsing stored raw payloads.
func ParseRacecards(body []byte, now time.Time) ([]domain.Race, error) {
	var page struct {
		Racecards []racecardDTO `json:"racecards"`
	}
	if err := (httpx.Response{Status: 200, Body: body}).Decode(&page); err != nil {
		return nil, err
	}
	var out []domain.Race
	for _, dto := range page.Racecards {
		if race, ok := mapRace(dto, now); ok {
			out = append(out, race)
		}
	}
	return out, nil
}

// TodaysResults is the free results endpoint, which covers today ONLY. A day
// not polled is a day lost, which is why the server polls it all evening.
func (c *Client) TodaysResults(ctx context.Context) ([]domain.RaceResult, error) {
	if err := c.configured(); err != nil {
		return nil, err
	}
	resp, err := c.http.Get(ctx, "/v1/results/today/free", nil, c.auth())
	if err != nil {
		return nil, err
	}
	return ParseResults(resp.Body, c.now())
}

// ParseResults decodes a results page.
func ParseResults(body []byte, now time.Time) ([]domain.RaceResult, error) {
	var page struct {
		Results []resultDTO `json:"results"`
	}
	if err := (httpx.Response{Status: 200, Body: body}).Decode(&page); err != nil {
		return nil, err
	}
	var out []domain.RaceResult
	for _, dto := range page.Results {
		if r, ok := mapResult(dto, now); ok {
			out = append(out, r)
		}
	}
	return out, nil
}

// FormHistory is the Basic-tier per-horse endpoint. On the free tier the first
// 403 latches and every later call is TierUnavailable without touching the
// network: twenty runners would otherwise burn twenty rate-limit slots.
func (c *Client) FormHistory(ctx context.Context, horseID string) ([]byte, error) {
	if err := c.configured(); err != nil {
		return nil, err
	}
	c.mu.Lock()
	refused := c.formHistoryRefused
	c.mu.Unlock()
	if refused {
		return nil, &httpx.Error{Kind: httpx.TierUnavailable, Message: "Form history"}
	}
	resp, err := c.http.Get(ctx, "/v1/racecards/"+url.PathEscape(horseID)+"/results", nil, c.auth())
	if httpx.KindOf(err) == httpx.Forbidden {
		c.mu.Lock()
		c.formHistoryRefused = true
		c.mu.Unlock()
		return nil, &httpx.Error{Kind: httpx.TierUnavailable, Message: "Form history"}
	}
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	c.formHistoryDetected = true
	c.mu.Unlock()
	return resp.Body, nil
}

// HasFormHistory says whether the paid endpoint has answered.
func (c *Client) HasFormHistory() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.formHistoryDetected && !c.formHistoryRefused
}

// MARK: - Wire types. Every field is lenient: one odd value must not cost us
// the card.

type courseDTO struct {
	ID         Text `json:"id"`
	Course     Text `json:"course"`
	RegionCode Text `json:"region_code"`
	Region     Text `json:"region"`
}

type racecardDTO struct {
	RaceID     Text        `json:"race_id"`
	Course     Text        `json:"course"`
	CourseID   Text        `json:"course_id"`
	Date       Text        `json:"date"`
	OffTime    Text        `json:"off_time"`
	OffDt      Text        `json:"off_dt"`
	RaceName   Text        `json:"race_name"`
	DistanceF  Number      `json:"distance_f"`
	Region     Text        `json:"region"`
	Pattern    Text        `json:"pattern"`
	RaceClass  Text        `json:"race_class"`
	Type       Text        `json:"type"`
	AgeBand    Text        `json:"age_band"`
	RatingBand Text        `json:"rating_band"`
	Prize      Text        `json:"prize"`
	FieldSize  Number      `json:"field_size"`
	Going      Text        `json:"going"`
	Surface    Text        `json:"surface"`
	RaceStatus Text        `json:"race_status"`
	Runners    []runnerDTO `json:"runners"`
}

type runnerDTO struct {
	HorseID   Text   `json:"horse_id"`
	Horse     Text   `json:"horse"`
	Age       Number `json:"age"`
	Sex       Text   `json:"sex"`
	Region    Text   `json:"region"`
	Number    Number `json:"number"`
	Draw      Number `json:"draw"`
	Headgear  Text   `json:"headgear"`
	Lbs       Number `json:"lbs"`
	Ofr       Number `json:"ofr"`
	LastRun   Number `json:"last_run"`
	Form      Text   `json:"form"`
	Jockey    Text   `json:"jockey"`
	JockeyID  Text   `json:"jockey_id"`
	Trainer   Text   `json:"trainer"`
	TrainerID Text   `json:"trainer_id"`
	Owner     Text   `json:"owner"`
	Sire      Text   `json:"sire"`
	Dam       Text   `json:"dam"`
	RPR       Number `json:"rpr"`
	TS        Number `json:"ts"`
	Spotlight Text   `json:"spotlight"`
	SilkURL   Text   `json:"silk_url"`
}

type resultDTO struct {
	RaceID   Text              `json:"race_id"`
	Course   Text              `json:"course"`
	Date     Text              `json:"date"`
	OffDt    Text              `json:"off_dt"`
	RaceName Text              `json:"race_name"`
	DistF    Number            `json:"dist_f"`
	Class    Text              `json:"class"`
	Type     Text              `json:"type"`
	Going    Text              `json:"going"`
	Surface  Text              `json:"surface"`
	Runners  []resultRunnerDTO `json:"runners"`
}

type resultRunnerDTO struct {
	HorseID   Text   `json:"horse_id"`
	Horse     Text   `json:"horse"`
	Position  Text   `json:"position"`
	Number    Number `json:"number"`
	Draw      Number `json:"draw"`
	WeightLbs Number `json:"weight_lbs"`
	OR        Number `json:"or"`
	JockeyID  Text   `json:"jockey_id"`
	TrainerID Text   `json:"trainer_id"`
	SpDec     Number `json:"sp_dec"`
}

// MARK: - Mapping. A value we cannot trust becomes nil, never a default.

func mapCourse(dto courseDTO) (domain.Course, bool) {
	id, name := dto.ID.NonEmpty(), dto.Course.NonEmpty()
	if id == nil || name == nil {
		return domain.Course{}, false
	}
	return domain.Course{ID: *id, Name: *name, RegionCode: strings.ToLower(dto.RegionCode.Or("")), Region: dto.Region.Or("")}, true
}

func mapRace(dto racecardDTO, now time.Time) (domain.Race, bool) {
	id := dto.RaceID.NonEmpty()
	if id == nil {
		return domain.Race{}, false
	}
	date := dto.Date.Or(domain.DayString(now))
	off := dto.OffTime.Or("")
	r := domain.Race{
		ID: *id, CourseName: dto.Course.Or("Unknown course"), CourseID: dto.CourseID.NonEmpty(),
		Name: dto.RaceName.Or("Race"), OffTime: off, Date: date,
		Distance: domain.NewDistance(dto.DistanceF.Float()), Going: domain.ParseGoing(dto.Going.Or("")),
		Surface: domain.ParseSurface(dto.Surface.Or("")), Type: domain.ParseRaceType(dto.Type.Or("")),
		RaceClass: raceClass(dto.RaceClass.NonEmpty()), Pattern: dto.Pattern.NonEmpty(), AgeBand: dto.AgeBand.NonEmpty(),
		RatingBand: ratingBand(dto.RatingBand.NonEmpty()), Prize: dto.Prize.NonEmpty(), FieldSize: dto.FieldSize.Int(),
		RegionCode: lower(dto.Region.NonEmpty()), Status: dto.RaceStatus.NonEmpty(), Runners: []domain.Runner{},
	}
	if t, ok := domain.ParseTimestamp(dto.OffDt.Or("")); ok {
		r.OffDateTime = domain.Ptr(t)
	} else if t, ok := domain.Combine(date, off); ok {
		r.OffDateTime = domain.Ptr(t)
	}
	for _, rd := range dto.Runners {
		if runner, ok := mapRunner(rd); ok {
			r.Runners = append(r.Runners, runner)
		}
	}
	return r, true
}

func mapRunner(dto runnerDTO) (domain.Runner, bool) {
	id, name := dto.HorseID.NonEmpty(), dto.Horse.NonEmpty()
	if id == nil || name == nil {
		return domain.Runner{}, false
	}
	return domain.Runner{
		ID: *id, Name: *name, ClothNumber: dto.Number.Int(), Draw: dto.Draw.Int(), Age: dto.Age.Int(),
		Sex: dto.Sex.NonEmpty(), RegionCode: dto.Region.NonEmpty(), OfficialRating: dto.Ofr.Int(),
		WeightPounds: dto.Lbs.Int(), Headgear: dto.Headgear.NonEmpty(), Form: dto.Form.NonEmpty(),
		DaysSinceLastRun: dto.LastRun.Int(), JockeyID: dto.JockeyID.NonEmpty(), JockeyName: dto.Jockey.NonEmpty(),
		TrainerID: dto.TrainerID.NonEmpty(), TrainerName: dto.Trainer.NonEmpty(), OwnerName: dto.Owner.NonEmpty(),
		SireName: dto.Sire.NonEmpty(), DamName: dto.Dam.NonEmpty(), RacingPostRating: dto.RPR.Int(),
		TopspeedRating: dto.TS.Int(), Spotlight: dto.Spotlight.NonEmpty(), SilkURL: dto.SilkURL.NonEmpty(),
	}, true
}

func mapResult(dto resultDTO, now time.Time) (domain.RaceResult, bool) {
	id := dto.RaceID.NonEmpty()
	if id == nil {
		return domain.RaceResult{}, false
	}
	r := domain.RaceResult{
		ID: *id, CourseName: dto.Course.Or("Unknown course"), Name: dto.RaceName.Or("Race"),
		Date: dto.Date.Or(domain.DayString(now)), Distance: domain.NewDistance(dto.DistF.Float()),
		Going: domain.ParseGoing(dto.Going.Or("")), Surface: domain.ParseSurface(dto.Surface.Or("")),
		Type: domain.ParseRaceType(dto.Type.Or("")), RaceClass: raceClass(dto.Class.NonEmpty()),
		Finishers: []domain.Finisher{},
	}
	if t, ok := domain.ParseTimestamp(dto.OffDt.Or("")); ok {
		r.OffDateTime = domain.Ptr(t)
	}
	for _, f := range dto.Runners {
		id := f.HorseID.NonEmpty()
		if id == nil {
			continue
		}
		r.Finishers = append(r.Finishers, domain.Finisher{
			HorseID: *id, HorseName: f.Horse.Or("Unknown"), Position: domain.ParseFinishPosition(f.Position.Value),
			ClothNumber: f.Number.Int(), Draw: f.Draw.Int(), WeightPounds: f.WeightLbs.Int(), OfficialRating: f.OR.Int(),
			JockeyID: f.JockeyID.NonEmpty(), TrainerID: f.TrainerID.NonEmpty(), StartingPriceDecimal: f.SpDec.Float(),
		})
	}
	return r, true
}

// raceClass reads "Class 4", "4" or "class4"; British racing runs 1-7.
func raceClass(raw *string) *int {
	if raw == nil {
		return nil
	}
	var digits strings.Builder
	for _, c := range *raw {
		if c >= '0' && c <= '9' {
			digits.WriteRune(c)
		}
	}
	v, err := strconv.Atoi(digits.String())
	if err != nil || v < 1 || v > 7 {
		return nil
	}
	return &v
}

// ratingBand reads "0-85".
func ratingBand(raw *string) *domain.ClosedRange {
	if raw == nil {
		return nil
	}
	parts := strings.SplitN(*raw, "-", 2)
	if len(parts) != 2 {
		return nil
	}
	lo, err1 := strconv.Atoi(strings.TrimSpace(parts[0]))
	hi, err2 := strconv.Atoi(strings.TrimSpace(parts[1]))
	if err1 != nil || err2 != nil || lo > hi {
		return nil
	}
	return &domain.ClosedRange{Lower: lo, Upper: hi}
}

func lower(s *string) *string {
	if s == nil {
		return nil
	}
	v := strings.ToLower(*s)
	return &v
}

// IsNotConfigured reports a missing credential.
func IsNotConfigured(err error) bool {
	var e *httpx.Error
	return errors.As(err, &e) && e.Kind == httpx.NotConfigured
}
