// Package web serves IPvexa's lightweight browser and phone view: one self-contained
// page (no external scripts, fonts or CDNs, so it works fully offline).
package web

import (
	_ "embed"
	"net/http"
)

//go:embed index.html
var index []byte

// Register mounts the web view at /web/ and redirects / there.
func Register(mux *http.ServeMux) {
	page := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		// Everything is inline and same-origin; nothing is loaded from elsewhere.
		w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' blob: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'")
		w.Write(index)
	}
	mux.HandleFunc("GET /web/{$}", page)
	mux.HandleFunc("GET /web", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/web/", http.StatusFound) })
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/web/", http.StatusFound) })
}
