package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/bensuskins/races/server/internal/rating"
	"github.com/bensuskins/races/server/internal/service"
	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers/legacy"
)

func TestOpenAPIContract(t *testing.T) {
	ctx := context.Background()
	data, err := documentation.ReadFile("openapi.json")
	if err != nil {
		t.Fatal(err)
	}
	spec, err := openapi3.NewLoader().LoadFromData(data)
	if err != nil {
		t.Fatal(err)
	}
	if err := spec.Validate(ctx); err != nil {
		t.Fatal(err)
	}
	spec.Servers = nil
	router, err := legacy.NewRouter(spec)
	if err != nil {
		t.Fatal(err)
	}
	server, svc := setup(t)
	svc.Execute(ctx, service.Everything)
	weights, _ := json.Marshal(rating.V3())
	cases := []struct{ method, path, body string }{
		{"GET", "/healthz", ""}, {"GET", "/metrics", ""}, {"GET", "/v1/status", ""},
		{"GET", "/v1/courses", ""}, {"GET", "/v1/racecards?day=today", ""}, {"GET", "/v1/races/rac_1001", ""},
		{"GET", "/v1/races/missing", ""}, {"GET", "/v1/tips", ""}, {"GET", "/v1/record", ""}, {"GET", "/v1/model", ""},
		{"POST", "/v1/import", `{"device":"contract"}`}, {"POST", "/v1/import", `{`},
		{"POST", "/v1/backtests", `{}`}, {"POST", "/v1/backtests", `{"unexpected":true}`},
		{"GET", "/v1/backtests", ""}, {"GET", "/v1/backtests/1", ""}, {"GET", "/v1/backtests/bad", ""},
		{"POST", "/v1/admin/weights", string(weights)}, {"POST", "/v1/admin/weights", `{}`},
		{"POST", "/v1/admin/jobs/courses", ""}, {"POST", "/v1/admin/jobs/unknown", ""},
	}
	covered := map[string]bool{}
	for _, tc := range cases {
		t.Run(tc.method+" "+tc.path, func(t *testing.T) {
			req, err := http.NewRequest(tc.method, server.URL+tc.path, strings.NewReader(tc.body))
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("Authorization", "Bearer "+token)
			if tc.body != "" {
				req.Header.Set("Content-Type", "application/json")
			}
			route, pathParams, err := router.FindRoute(req)
			if err != nil {
				t.Fatal(err)
			}
			covered[tc.method+" "+route.Path] = true
			res, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			body, err := io.ReadAll(res.Body)
			res.Body.Close()
			if err != nil {
				t.Fatal(err)
			}
			input := &openapi3filter.ResponseValidationInput{RequestValidationInput: &openapi3filter.RequestValidationInput{Request: req, PathParams: pathParams, Route: route}, Status: res.StatusCode, Header: res.Header, Body: io.NopCloser(bytes.NewReader(body))}
			if err := openapi3filter.ValidateResponse(ctx, input); err != nil {
				t.Fatalf("response %d: %v\n%s", res.StatusCode, err, body)
			}
			expected := http.StatusOK
			switch {
			case tc.path == "/v1/races/missing", tc.path == "/v1/admin/jobs/unknown":
				expected = http.StatusNotFound
			case tc.path == "/v1/backtests/bad", tc.body == "{", strings.Contains(tc.body, `"unexpected"`), tc.path == "/v1/admin/weights" && tc.body == "{}":
				expected = http.StatusBadRequest
			case tc.path == "/v1/admin/weights":
				expected = http.StatusCreated
			}
			if res.StatusCode != expected {
				t.Fatalf("expected %d, got %d: %s", expected, res.StatusCode, body)
			}
			if expected < 400 {
				if req.GetBody != nil {
					req.Body, err = req.GetBody()
					if err != nil {
						t.Fatal(err)
					}
				}
				requestInput := &openapi3filter.RequestValidationInput{Request: req, PathParams: pathParams, Route: route, Options: &openapi3filter.Options{AuthenticationFunc: openapi3filter.NoopAuthenticationFunc}}
				if err := openapi3filter.ValidateRequest(ctx, requestInput); err != nil {
					t.Fatalf("request: %v", err)
				}
			}
			if strings.HasPrefix(tc.path, "/v1/") {
				unauthorized, err := http.NewRequest(tc.method, server.URL+tc.path, nil)
				if err != nil {
					t.Fatal(err)
				}
				response, err := http.DefaultClient.Do(unauthorized)
				if err != nil {
					t.Fatal(err)
				}
				defer response.Body.Close()
				if response.StatusCode != http.StatusUnauthorized {
					t.Fatalf("missing token: status %d", response.StatusCode)
				}
				input.Status, input.Header, input.Body = response.StatusCode, response.Header, response.Body
				if err := openapi3filter.ValidateResponse(ctx, input); err != nil {
					t.Fatalf("unauthorized response: %v", err)
				}
			}
		})
	}
	for path, item := range spec.Paths.Map() {
		for method := range item.Operations() {
			if !covered[method+" "+path] {
				t.Errorf("missing operation coverage: %s %s", method, path)
			}
		}
	}
}

func TestDocumentationRoutes(t *testing.T) {
	server, _ := setup(t)
	for _, path := range []string{"/openapi.json", "/docs/", "/docs-assets/swagger-ui.css", "/docs-assets/swagger-ui-bundle.js"} {
		res, err := http.Get(server.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != http.StatusOK {
			t.Errorf("%s: status %d", path, res.StatusCode)
		}
	}
}

func TestOpenAPIDocumentsRegisteredRoutes(t *testing.T) {
	data, err := documentation.ReadFile("openapi.json")
	if err != nil {
		t.Fatal(err)
	}
	spec, err := openapi3.NewLoader().LoadFromData(data)
	if err != nil {
		t.Fatal(err)
	}
	source, err := os.ReadFile("api.go")
	if err != nil {
		t.Fatal(err)
	}
	expressions := regexp.MustCompile(`HandleFunc\("(GET|POST|PUT|PATCH|DELETE) ([^" ]+)"`).FindAllStringSubmatch(string(source), -1)
	for _, expression := range expressions {
		path := spec.Paths.Value(expression[2])
		if path == nil || path.GetOperation(expression[1]) == nil {
			t.Errorf("undocumented route: %s %s", expression[1], expression[2])
		}
	}
}
