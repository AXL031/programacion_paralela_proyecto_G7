package master

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"github.com/proyecto-g7/transporte/internal/ml"
	"io"
	"net/http"
	"strings"
	"time"
)

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, r *http.Request) { reply(w, 200, map[string]bool{"alive": true}) })
	mux.HandleFunc("GET /health/ready", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if s.Repo.Ping(ctx) != nil {
			reply(w, 503, map[string]bool{"ready": false})
			return
		}
		reply(w, 200, map[string]bool{"ready": true})
	})
	mux.HandleFunc("GET /cluster", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		active := s.active
		s.mu.Unlock()
		reply(w, 200, map[string]any{"workers": s.Workers(), "active_run": active, "master": s.Monitor.Sample(), "measurement_scope": "Go process; CPU 100 percent = one CPU core; RAM = resident set"})
	})
	mux.HandleFunc("POST /runs", func(w http.ResponseWriter, r *http.Request) {
		var c ml.Config
		d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192))
		d.DisallowUnknownFields()
		if err := d.Decode(&c); err != nil {
			reply(w, 400, map[string]string{"error": "invalid training configuration"})
			return
		}
		if err := d.Decode(&struct{}{}); err != io.EOF {
			reply(w, 400, map[string]string{"error": "one JSON object required"})
			return
		}
		if err := c.Validate(); err != nil {
			reply(w, 400, map[string]string{"error": err.Error()})
			return
		}
		run, err := s.Start(c)
		if err != nil {
			reply(w, 409, map[string]string{"error": err.Error()})
			return
		}
		reply(w, 202, run)
	})
	mux.HandleFunc("GET /runs/{id}", func(w http.ResponseWriter, r *http.Request) {
		if run, ok := s.Run(r.PathValue("id")); ok {
			reply(w, 200, run)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		run, err := s.Repo.TrainingRun(ctx, r.PathValue("id"))
		if err != nil {
			reply(w, 404, map[string]string{"error": "run not found"})
			return
		}
		reply(w, 200, run)
	})
	mux.HandleFunc("GET /models/{id}", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		model, err := s.Repo.Model(ctx, r.PathValue("id"))
		if err != nil {
			reply(w, 404, map[string]string{"error": "model not found"})
			return
		}
		reply(w, 200, model)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/health/") && s.Secret != "" && subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+s.Secret)) != 1 {
			reply(w, 401, map[string]string{"error": "internal token required"})
			return
		}
		mux.ServeHTTP(w, r)
	})
}
func reply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}
