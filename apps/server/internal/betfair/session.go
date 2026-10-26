// Package betfair is Betfair Exchange, read-only, on the free delayed app key.
// It never places a bet.
//
// Betfair reports failure with HTTP 200: a refused login is 200 with status
// FAIL, and a betting fault is 200 with an APINGException envelope that would
// otherwise decode as an empty list — indistinguishable from "no racing today".
// Every call here reads the body, never just the status.
package betfair

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/bensuskins/races/server/internal/httpx"
)

const (
	IdentityBaseURL = "https://identitysso.betfair.com"
	BettingBaseURL  = "https://api.betfair.com/exchange/betting/rest/v1.0"
	// KeepAliveAfter is conservative: Betfair's real lifetime is unmeasured, so
	// renewal is reactive and this only decides when a keep-alive is worth it.
	KeepAliveAfter = 4 * time.Hour
)

// Credentials are all three or nothing: half-configured would 401 and be
// reported as a wrong password.
type Credentials struct {
	AppKey, Username, Password string
}

func (c Credentials) Complete() bool {
	return c.AppKey != "" && c.Username != "" && c.Password != ""
}

// LoginFailure is why an interactive login produced no token. Code is always
// Betfair's own, verbatim, because an unrecognised code is the interesting one.
type LoginFailure struct {
	Code   string `json:"code"`
	Detail string `json:"detail,omitempty"`
}

// UnreadableResponse is not one of Betfair's codes: the body never parsed.
const UnreadableResponse = "UNREADABLE_RESPONSE"

func (f *LoginFailure) Error() string { return "betfair login: " + f.Message() }

// RequiresCertificateLogin: interactive login can never work for this account.
func (f *LoginFailure) RequiresCertificateLogin() bool {
	return f.Code == "CERT_AUTH_REQUIRED" || f.Code == "SECURITY_RESTRICTED_LOCATION"
}

// RequiresUserAction: a human in a browser has to clear something first.
func (f *LoginFailure) RequiresUserAction() bool {
	switch f.Code {
	case "SECURITY_QUESTION_REQUIRED", "PENDING_AUTH", "ACCOUNT_PENDING_PASSWORD_CHANGE", "ACCOUNT_NOW_LOCKED",
		"ACCOUNT_ALREADY_LOCKED", "TEMPORARY_BAN_TOO_MANY_REQUESTS", "ACTIONS_REQUIRED", "DUPLICATE_CARDS",
		"CHANGE_PASSWORD_REQUIRED", "CLOSED_ACCOUNT", "SUSPENDED_ACCOUNT", "SELF_EXCLUDED", "TRADING_MASTER_SUSPENDED":
		return true
	}
	return false
}

func (f *LoginFailure) IsBadCredentials() bool {
	switch f.Code {
	case "INVALID_USERNAME_OR_PASSWORD", "INVALID_USERNAME", "INVALID_PASSWORD":
		return true
	}
	return false
}

// Class is the one-word classification /v1/status reports.
func (f *LoginFailure) Class() string {
	switch {
	case f.Code == UnreadableResponse:
		return "unreadableResponse"
	case f.RequiresCertificateLogin():
		return "certificateRequired"
	case f.IsBadCredentials():
		return "badCredentials"
	case f.RequiresUserAction():
		return "userActionRequired"
	}
	return "refused"
}

// Message is plain copy, never "check your password" unless that is the fix.
func (f *LoginFailure) Message() string {
	switch {
	case f.Code == UnreadableResponse:
		return "Betfair answered with something that isn't a login reply, so the credentials were never checked. " +
			"This is what a jurisdiction block, a captive portal or a network proxy looks like. (" + f.Detail + ")"
	case f.RequiresCertificateLogin():
		return "Betfair requires a certificate login for this account, which the server doesn't support yet."
	case f.IsBadCredentials():
		return "Betfair didn't recognise that username and password."
	case f.RequiresUserAction():
		return "Betfair needs you to sign in on their website first (" + f.Code + ")."
	}
	return "Betfair refused the login (" + f.Code + ")."
}

// Session holds the token. A 2FA or certificate failure is LATCHED: retrying
// it on every refresh would look like a hang and could lock the account. An
// unreadable reply is not latched — its cause is outside the account.
type Session struct {
	creds Credentials
	http  *httpx.Client
	now   func() time.Time

	mu        sync.Mutex
	token     string
	obtained  time.Time
	permanent *LoginFailure
	last      *LoginFailure
}

func NewSession(creds Credentials, http *httpx.Client, now func() time.Time) *Session {
	if now == nil {
		now = time.Now
	}
	return &Session{creds: creds, http: http, now: now}
}

// Token returns the current token, logging in if there is none.
func (s *Session) Token(ctx context.Context) (string, error) {
	s.mu.Lock()
	if s.permanent != nil {
		p := s.permanent
		s.mu.Unlock()
		return "", p
	}
	if s.token != "" {
		t := s.token
		s.mu.Unlock()
		return t, nil
	}
	s.mu.Unlock()
	return s.LogIn(ctx)
}

// Invalidate drops the token; the next call logs in again.
func (s *Session) Invalidate() {
	s.mu.Lock()
	s.token = ""
	s.mu.Unlock()
}

// LastFailure is the most recent login failure, for diagnostics.
func (s *Session) LastFailure() *LoginFailure {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.last
}

func (s *Session) HasToken() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.token != ""
}

// LogIn performs an interactive login.
func (s *Session) LogIn(ctx context.Context) (string, error) {
	if !s.creds.Complete() {
		return "", &httpx.Error{Kind: httpx.NotConfigured, Message: "Betfair"}
	}
	resp, err := s.http.PostForm(ctx, "/api/login",
		url.Values{"username": {s.creds.Username}, "password": {s.creds.Password}},
		httpx.Headers(map[string]string{"X-Application": s.creds.AppKey, "Accept": "application/json"}))
	if err != nil && resp.Body == nil {
		return "", err
	}
	var body struct {
		Token  *string `json:"token"`
		Status *string `json:"status"`
		Error  *string `json:"error"`
	}
	if jerr := json.Unmarshal(resp.Body, &body); jerr != nil {
		// Not a decoding error: what came back instead IS the finding.
		f := &LoginFailure{Code: UnreadableResponse, Detail: httpx.NewShape(resp.Status, resp.ContentType, resp.Body).String()}
		s.record(f, false)
		return "", f
	}
	if err != nil {
		return "", err
	}
	token := deref(body.Token)
	if deref(body.Status) != "SUCCESS" || token == "" {
		code := strings.TrimSpace(deref(body.Error))
		if code == "" {
			code = strings.TrimSpace(deref(body.Status))
		}
		if code == "" {
			code = "UNKNOWN"
		}
		f := &LoginFailure{Code: code}
		s.record(f, f.RequiresCertificateLogin() || f.RequiresUserAction())
		return "", f
	}
	s.mu.Lock()
	s.token, s.obtained, s.permanent, s.last = token, s.now(), nil, nil
	s.mu.Unlock()
	return token, nil
}

func (s *Session) record(f *LoginFailure, permanent bool) {
	s.mu.Lock()
	s.last = f
	if permanent {
		s.permanent = f
	}
	s.mu.Unlock()
}

// KeepAliveIfNeeded extends an old session. A refused keep-alive drops the
// token rather than keeping one known to be dead.
func (s *Session) KeepAliveIfNeeded(ctx context.Context) (bool, error) {
	s.mu.Lock()
	token, obtained := s.token, s.obtained
	s.mu.Unlock()
	if token == "" || s.now().Sub(obtained) < KeepAliveAfter {
		return false, nil
	}
	resp, err := s.http.PostForm(ctx, "/api/keepAlive", url.Values{},
		httpx.Headers(map[string]string{"X-Application": s.creds.AppKey, "X-Authentication": token, "Accept": "application/json"}))
	if err != nil {
		return false, err
	}
	var body struct {
		Token  string `json:"token"`
		Status string `json:"status"`
	}
	if err := resp.Decode(&body); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if body.Status != "SUCCESS" {
		s.token = ""
		return false, nil
	}
	if body.Token != "" {
		s.token = body.Token
	}
	s.obtained = s.now()
	return true, nil
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// AsLoginFailure extracts a LoginFailure from an error chain.
func AsLoginFailure(err error) (*LoginFailure, bool) {
	var f *LoginFailure
	ok := errors.As(err, &f)
	return f, ok
}

// Fault is an APINGException the exchange sent in the body.
type Fault struct {
	Code    string
	Details string
}

func (f *Fault) Error() string {
	if f.Details != "" {
		return fmt.Sprintf("betfair fault %s: %s", f.Code, f.Details)
	}
	return "betfair fault " + f.Code
}

// InvalidSession is the one fault worth signing in again for.
func (f *Fault) InvalidSession() bool {
	switch f.Code {
	case "INVALID_SESSION_INFORMATION", "NO_SESSION", "SESSION_EXPIRED":
		return true
	}
	return false
}

// AsError maps a fault to the shared error kinds.
func (f *Fault) AsError() error {
	switch f.Code {
	case "INVALID_SESSION_INFORMATION", "NO_SESSION", "SESSION_EXPIRED":
		return &httpx.Error{Kind: httpx.Unauthorized, Message: "Betfair: " + f.Code}
	case "INVALID_APP_KEY", "NO_APP_KEY", "APP_KEY_CREATION_FAILED", "ACCESS_DENIED":
		return &httpx.Error{Kind: httpx.Forbidden, Message: "Betfair: " + f.Code}
	case "TOO_MANY_REQUESTS":
		return &httpx.Error{Kind: httpx.RateLimited, Message: "Betfair: " + f.Code}
	case "SERVICE_BUSY":
		return &httpx.Error{Kind: httpx.Server, Status: 503, Message: "Betfair is busy"}
	case "TIMEOUT":
		return &httpx.Error{Kind: httpx.TimedOut, Message: "Betfair: " + f.Code}
	case "TOO_MUCH_DATA":
		return &httpx.Error{Kind: httpx.BadRequest, Message: "Betfair: request too large even when split"}
	}
	return &httpx.Error{Kind: httpx.BadRequest, Message: "Betfair: " + f.Code}
}
