package api

import (
	"embed"
	"io/fs"
	"net/http"
)

// Swagger UI 5.30.3 is from https://www.npmjs.com/package/swagger-ui-dist.
// Its Apache-2.0 license is included in swagger/LICENSE.
//
//go:embed openapi.json swagger/*
var documentation embed.FS

func (s *Server) registerDocumentation(mux *http.ServeMux) {
	mux.HandleFunc("GET /openapi.json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		data, _ := documentation.ReadFile("openapi.json")
		_, _ = w.Write(data)
	})
	mux.HandleFunc("GET /docs/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/docs/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!doctype html><html><head><meta charset="utf-8"><title>Races API</title><link rel="stylesheet" href="/docs-assets/swagger-ui.css"></head><body><div id="swagger-ui"></div><script src="/docs-assets/swagger-ui-bundle.js"></script><script>SwaggerUIBundle({url: '/openapi.json', dom_id: '#swagger-ui', persistAuthorization: false});</script></body></html>`))
	})
	mux.Handle("GET /docs-assets/", http.StripPrefix("/docs-assets/", http.FileServer(http.FS(mustSwaggerFS()))))
}

func mustSwaggerFS() fs.FS {
	files, err := fs.Sub(documentation, "swagger")
	if err != nil {
		panic(err)
	}
	return files
}
