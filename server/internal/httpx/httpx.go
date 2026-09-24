// Package httpx is the one HTTP pipeline every provider call goes through:
// rate limiting, retry of idempotent calls, status mapping, and decode errors
// that carry what arrived instead.
package httpx

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/rand/v2"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

// Kind classifies a failure the way APIError does in the app.
type Kind string

const (
	Offline         Kind = "offline"
	TimedOut        Kind = "timedOut"
	Network         Kind = "network"
	Unauthorized    Kind = "unauthorized"
	Forbidden       Kind = "forbidden"
	NotFound        Kind = "notFound"
	Conflict        Kind = "conflict"
	BadRequest      Kind = "badRequest"
	RateLimited     Kind = "rateLimited"
	Server          Kind = "server"
	Decoding        Kind = "decoding"
	TierUnavailable Kind = "tierUnavailable"
	NotConfigured   Kind = "notConfigured"
)

// Error is a provider failure.
type Error struct {
	Kind       Kind
	Status     int
	Message    string
	RetryAfter time.Duration
	Shape      *ResponseShape
}

func (e *Error) Error() string {
	switch {
	case e.Shape != nil:
		return fmt.Sprintf("%s: couldn't read the reply — %s", e.Kind, e.Shape)
	case e.Message != "":
		return fmt.Sprintf("%s (%d): %s", e.Kind, e.Status, e.Message)
	case e.Status != 0:
		return fmt.Sprintf("%s (%d)", e.Kind, e.Status)
	}
	return string(e.Kind)
}

// Retryable: transient network trouble, rate limiting and 5xx only.
func (e *Error) Retryable() bool {
	switch e.Kind {
	case Offline, TimedOut, RateLimited, Network:
		return true
	case Server:
		return e.Status >= 500
	}
	return false
}

// IsExpectedLimitation is a missing tier or provider: information, not an error.
func (e *Error) IsExpectedLimitation() bool {
	return e.Kind == TierUnavailable || e.Kind == NotConfigured
}

// KindOf returns the Kind of an *Error anywhere in the chain, or "".
func KindOf(err error) Kind {
	var e *Error
	if errors.As(err, &e) {
		return e.Kind
	}
	return ""
}

// ResponseShape describes a reply that could not be decoded: status, content
// type, size and a whitespace-collapsed, token-redacted snippet. "Unexpected
// response, try again" names nothing and sends people to re-type a password
// that was never checked.
type ResponseShape struct {
	StatusCode  int    `json:"statusCode"`
	ContentType string `json:"contentType,omitempty"`
	ByteCount   int    `json:"byteCount"`
	Snippet     string `json:"snippet"`
}

const snippetLimit = 160

// NewShape builds the shape of a body.
func NewShape(status int, contentType string, body []byte) *ResponseShape {
	ct := strings.ToLower(strings.TrimSpace(strings.SplitN(contentType, ";", 2)[0]))
	return &ResponseShape{StatusCode: status, ContentType: ct, ByteCount: len(body), Snippet: snippet(body)}
}

func snippet(body []byte) string {
	if len(body) == 0 {
		return "(empty body)"
	}
	if !utf8Valid(body) {
		return "(not UTF-8)"
	}
	collapsed := strings.Join(strings.Fields(string(body)), " ")
	redacted := redact(collapsed)
	if r := []rune(redacted); len(r) > snippetLimit {
		return string(r[:snippetLimit]) + "…"
	}
	return redacted
}

func utf8Valid(b []byte) bool { return strings.ToValidUTF8(string(b), "�") == string(b) }

// redact replaces any run of 20+ letters or digits — a session token, an app
// key — with an ellipsis.
func redact(text string) string {
	var out, run strings.Builder
	flush := func() {
		if len([]rune(run.String())) >= 20 {
			out.WriteString("…")
		} else {
			out.WriteString(run.String())
		}
		run.Reset()
	}
	for _, c := range text {
		if unicode.IsLetter(c) || unicode.IsNumber(c) {
			run.WriteRune(c)
			continue
		}
		flush()
		out.WriteRune(c)
	}
	flush()
	return out.String()
}

func (s ResponseShape) String() string {
	ct := s.ContentType
	if ct == "" {
		ct = "no content type"
	}
	return fmt.Sprintf("HTTP %d, %s, %d bytes: %s", s.StatusCode, ct, s.ByteCount, s.Snippet)
}

// LooksLikeHTML: a jurisdiction block, captive portal or proxy.
func (s ResponseShape) LooksLikeHTML() bool {
	lower := strings.ToLower(s.Snippet)
	return strings.Contains(s.ContentType, "html") || strings.HasPrefix(lower, "<!doctype") || strings.HasPrefix(lower, "<html")
}

// RateLimiter spaces requests at least 1/rps apart. Each caller reserves its
// own slot, so concurrent callers queue rather than burst.
type RateLimiter struct {
	mu       sync.Mutex
	interval time.Duration
	next     time.Time
}

func NewRateLimiter(rps float64) *RateLimiter {
	l := &RateLimiter{}
	if rps > 0 {
		l.interval = time.Duration(float64(time.Second) / rps)
	}
	return l
}

func (l *RateLimiter) Wait(ctx context.Context) error {
	if l.interval <= 0 {
		return nil
	}
	l.mu.Lock()
	now := time.Now()
	scheduled := now
	if l.next.After(now) {
		scheduled = l.next
	}
	l.next = scheduled.Add(l.interval)
	l.mu.Unlock()
	if wait := time.Until(scheduled); wait > 0 {
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

// RetryPolicy is capped exponential backoff with jitter.
type RetryPolicy struct {
	MaxAttempts int
	BaseDelay   time.Duration
	MaxDelay    time.Duration
	Jitter      float64
}

var DefaultRetry = RetryPolicy{MaxAttempts: 3, BaseDelay: 500 * time.Millisecond, MaxDelay: 8 * time.Second, Jitter: 0.2}
var NoRetry = RetryPolicy{MaxAttempts: 1}

func (p RetryPolicy) delay(attempt int, retryAfter time.Duration) time.Duration {
	if retryAfter > 0 {
		return min(retryAfter, p.MaxDelay)
	}
	d := math.Min(float64(p.BaseDelay)*math.Pow(2, float64(attempt-1)), float64(p.MaxDelay))
	j := d * p.Jitter
	return time.Duration(d + (rand.Float64()*2-1)*j)
}

// Auth decorates a request.
type Auth func(*http.Request)

func Basic(user, pass string) Auth { return func(r *http.Request) { r.SetBasicAuth(user, pass) } }

func Headers(h map[string]string) Auth {
	return func(r *http.Request) {
		for k, v := range h {
			r.Header.Set(k, v)
		}
	}
}

// Recorder receives every response body, so raw provider payloads can be kept
// for retraining against fields we do not parse today.
type Recorder func(method, path, query string, status int, body []byte)

// Client is one provider's HTTP pipeline.
type Client struct {
	BaseURL  string
	HTTP     *http.Client
	Limiter  *RateLimiter
	Retry    RetryPolicy
	Recorder Recorder
}

func New(baseURL string, rps float64, httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 30 * time.Second}
	}
	return &Client{BaseURL: strings.TrimRight(baseURL, "/"), HTTP: httpClient, Limiter: NewRateLimiter(rps), Retry: DefaultRetry}
}

// Response is what came back.
type Response struct {
	Status      int
	ContentType string
	Body        []byte
}

// Decode unmarshals the body, or returns a Decoding error carrying its shape.
func (r Response) Decode(v any) error {
	if err := json.Unmarshal(r.Body, v); err != nil {
		return &Error{Kind: Decoding, Status: r.Status, Shape: NewShape(r.Status, r.ContentType, r.Body)}
	}
	return nil
}

// Get is retried on transient failure.
func (c *Client) Get(ctx context.Context, path string, query url.Values, auth Auth) (Response, error) {
	return c.do(ctx, http.MethodGet, path, query, nil, "", auth)
}

// PostJSON is never retried: a POST is not idempotent.
func (c *Client) PostJSON(ctx context.Context, path string, body any, auth Auth) (Response, error) {
	data, err := json.Marshal(body)
	if err != nil {
		return Response{}, &Error{Kind: Decoding, Message: err.Error()}
	}
	return c.do(ctx, http.MethodPost, path, nil, data, "application/json", auth)
}

// PostForm encodes the form. url.Values escapes '+' as %2B, which matters:
// Betfair passwords routinely contain one, and a bare '+' decodes as a space.
func (c *Client) PostForm(ctx context.Context, path string, form url.Values, auth Auth) (Response, error) {
	return c.do(ctx, http.MethodPost, path, nil, []byte(form.Encode()), "application/x-www-form-urlencoded", auth)
}

func (c *Client) do(ctx context.Context, method, path string, query url.Values, body []byte, contentType string, auth Auth) (Response, error) {
	idempotent := method == http.MethodGet
	var last error
	for attempt := 1; ; attempt++ {
		resp, err := c.once(ctx, method, path, query, body, contentType, auth)
		if err == nil {
			return resp, nil
		}
		last = err
		var e *Error
		if !idempotent || attempt >= c.Retry.MaxAttempts || !errors.As(err, &e) || !e.Retryable() {
			return resp, last
		}
		select {
		case <-time.After(c.Retry.delay(attempt, e.RetryAfter)):
		case <-ctx.Done():
			return resp, ctx.Err()
		}
	}
}

func (c *Client) once(ctx context.Context, method, path string, query url.Values, body []byte, contentType string, auth Auth) (Response, error) {
	u := c.BaseURL + "/" + strings.TrimLeft(path, "/")
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u, bytes.NewReader(body))
	if err != nil {
		return Response{}, &Error{Kind: BadRequest, Message: "couldn't build a URL for " + path}
	}
	req.Header.Set("Accept", "application/json")
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if auth != nil {
		auth(req)
	}
	if err := c.Limiter.Wait(ctx); err != nil {
		return Response{}, err
	}
	res, err := c.HTTP.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return Response{}, ctx.Err()
		}
		var ne interface{ Timeout() bool }
		if errors.As(err, &ne) && ne.Timeout() {
			return Response{}, &Error{Kind: TimedOut, Message: err.Error()}
		}
		return Response{}, &Error{Kind: Network, Message: err.Error()}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 32<<20))
	if err != nil {
		return Response{}, &Error{Kind: Network, Message: err.Error()}
	}
	resp := Response{Status: res.StatusCode, ContentType: res.Header.Get("Content-Type"), Body: data}
	if c.Recorder != nil {
		c.Recorder(method, path, query.Encode(), res.StatusCode, data)
	}
	if res.StatusCode >= 200 && res.StatusCode <= 299 {
		return resp, nil
	}
	return resp, mapStatus(res, data)
}

func mapStatus(res *http.Response, body []byte) *Error {
	msg := strings.TrimSpace(string(body))
	if len(msg) > 200 {
		msg = ""
	}
	switch res.StatusCode {
	case 400, 422:
		return &Error{Kind: BadRequest, Status: res.StatusCode, Message: msg}
	case 401:
		return &Error{Kind: Unauthorized, Status: 401}
	case 403:
		return &Error{Kind: Forbidden, Status: 403}
	case 404:
		return &Error{Kind: NotFound, Status: 404}
	case 409:
		return &Error{Kind: Conflict, Status: 409}
	case 429:
		e := &Error{Kind: RateLimited, Status: 429}
		if s, err := strconv.ParseFloat(res.Header.Get("Retry-After"), 64); err == nil {
			e.RetryAfter = time.Duration(s * float64(time.Second))
		}
		return e
	}
	return &Error{Kind: Server, Status: res.StatusCode, Message: msg}
}
