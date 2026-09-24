package httpx

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func server(t *testing.T, h http.HandlerFunc) *Client {
	t.Helper()
	s := httptest.NewServer(h)
	t.Cleanup(s.Close)
	c := New(s.URL, 0, nil)
	c.Retry = RetryPolicy{MaxAttempts: 3, BaseDelay: time.Millisecond, MaxDelay: time.Millisecond}
	return c
}

func TestBuildsURLAndAuth(t *testing.T) {
	c := server(t, func(w http.ResponseWriter, r *http.Request) {
		user, pass, _ := r.BasicAuth()
		if r.URL.Path != "/v1/courses" || r.URL.Query()["region_codes"][1] != "ire" || user != "u" || pass != "p" {
			t.Errorf("got %s %v %s", r.URL.Path, r.URL.Query(), user)
		}
		w.Write([]byte(`{}`))
	})
	if _, err := c.Get(context.Background(), "v1/courses", url.Values{"region_codes": {"gb", "ire"}}, Basic("u", "p")); err != nil {
		t.Fatal(err)
	}
}

// A '+' in a form body decodes as a space; Betfair passwords contain them.
func TestFormPostEncodesPlus(t *testing.T) {
	c := server(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), "password=a%2Bb") || r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" {
			t.Errorf("body %s", body)
		}
		w.Write([]byte(`{}`))
	})
	if _, err := c.PostForm(context.Background(), "/api/login", url.Values{"password": {"a+b"}}, nil); err != nil {
		t.Fatal(err)
	}
}

func TestStatusMapping(t *testing.T) {
	cases := map[int]Kind{400: BadRequest, 401: Unauthorized, 403: Forbidden, 404: NotFound, 409: Conflict, 429: RateLimited, 500: Server}
	for status, kind := range cases {
		c := server(t, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Retry-After", "0.001")
			w.WriteHeader(status)
		})
		c.Retry = NoRetry
		_, err := c.Get(context.Background(), "/", nil, nil)
		if KindOf(err) != kind {
			t.Fatalf("%d: got %v", status, err)
		}
	}
}

func TestDecodeFailureCarriesTheShape(t *testing.T) {
	c := server(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte("<!DOCTYPE html>\n<html>  Access denied token=abcdefghijklmnopqrstuvwxyz0123 </html>"))
	})
	resp, _ := c.Get(context.Background(), "/", nil, nil)
	var v map[string]any
	err := resp.Decode(&v)
	var e *Error
	if !errors.As(err, &e) || e.Shape == nil || !e.Shape.LooksLikeHTML() || e.Shape.ContentType != "text/html" {
		t.Fatalf("%v", err)
	}
	if strings.Contains(e.Shape.Snippet, "abcdefghijklmnopqrstuvwxyz") || strings.Contains(e.Shape.Snippet, "\n") {
		t.Fatal("token must be redacted and whitespace collapsed:", e.Shape.Snippet)
	}
}

func TestRetriesOnlyIdempotentTransientFailures(t *testing.T) {
	var calls atomic.Int32
	c := server(t, func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) < 3 {
			w.WriteHeader(503)
			return
		}
		w.Write([]byte(`{}`))
	})
	if _, err := c.Get(context.Background(), "/", nil, nil); err != nil || calls.Load() != 3 {
		t.Fatal("GET retries 5xx", err, calls.Load())
	}
	calls.Store(0)
	if _, err := c.PostJSON(context.Background(), "/", map[string]int{}, nil); err == nil || calls.Load() != 1 {
		t.Fatal("POST is never retried")
	}
	calls.Store(0)
	c404 := server(t, func(w http.ResponseWriter, r *http.Request) { calls.Add(1); w.WriteHeader(404) })
	c404.Get(context.Background(), "/", nil, nil)
	if calls.Load() != 1 {
		t.Fatal("client errors are not retried")
	}
}

func TestRateLimiterPaces(t *testing.T) {
	l := NewRateLimiter(50)
	start := time.Now()
	for range 3 {
		l.Wait(context.Background())
	}
	if time.Since(start) < 35*time.Millisecond {
		t.Fatal("three calls at 50/s take at least 40ms")
	}
}

func TestRecorderSeesEveryBody(t *testing.T) {
	c := server(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"a":1}`)) })
	var got string
	c.Recorder = func(method, path, query string, status int, body []byte) { got = method + path + string(body) }
	c.Get(context.Background(), "/x", nil, nil)
	if got != `GET/x{"a":1}` {
		t.Fatal(got)
	}
}
