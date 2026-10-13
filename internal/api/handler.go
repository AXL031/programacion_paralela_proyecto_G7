package api

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/proyecto-g7/transporte/internal/domain"
	driver "go.mongodb.org/mongo-driver/v2/mongo"
	"net/http"
	"strconv"
	"time"
)

type Data interface {
	Ping(context.Context) error
	Current(context.Context) (*domain.Manifest, error)
	Observations(context.Context, string, int, time.Time, time.Time) ([]domain.Window, error)
}
type Probe func(context.Context) error

func New(data Data, redis Probe, options ...Options) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, r *http.Request) { send(w, 200, map[string]string{"status": "alive"}) })
	mux.HandleFunc("GET /health/ready", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		mongoErr := data.Ping(ctx)
		redisErr := redis(ctx)
		code := 200
		if mongoErr != nil {
			code = 503
		}
		send(w, code, map[string]any{"ready": code == 200, "mongo": mongoErr == nil, "redis": redisErr == nil})
	})
	current := func(w http.ResponseWriter, r *http.Request) (*domain.Manifest, context.Context, context.CancelFunc) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		m, err := data.Current(ctx)
		if errors.Is(err, driver.ErrNoDocuments) || err == nil && m == nil {
			send(w, 404, map[string]string{"error": "no completed dataset"})
			return nil, ctx, cancel
		}
		if err != nil {
			send(w, 503, map[string]string{"error": "dataset storage unavailable"})
			return nil, ctx, cancel
		}
		return m, ctx, cancel
	}
	mux.HandleFunc("GET /api/v1/datasets/current", func(w http.ResponseWriter, r *http.Request) {
		m, _, cancel := current(w, r)
		defer cancel()
		if m != nil {
			send(w, 200, m)
		}
	})
	mux.HandleFunc("GET /api/v1/zones", func(w http.ResponseWriter, r *http.Request) {
		m, _, cancel := current(w, r)
		defer cancel()
		if m != nil {
			send(w, 200, m.Zones)
		}
	})
	mux.HandleFunc("GET /api/v1/observations", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		zone, err := strconv.Atoi(q.Get("zone_id"))
		if err != nil || zone < 1 || zone > 263 {
			send(w, 400, map[string]string{"error": "zone_id between 1 and 263 is required"})
			return
		}
		start, err := time.Parse(time.RFC3339, q.Get("start"))
		if err != nil {
			send(w, 400, map[string]string{"error": "start must be RFC3339 with offset"})
			return
		}
		end, err := time.Parse(time.RFC3339, q.Get("end"))
		if err != nil || !end.After(start) || end.Sub(start) > 24*time.Hour {
			send(w, 400, map[string]string{"error": "end must be after start; maximum range is 24 hours"})
			return
		}
		m, ctx, cancel := current(w, r)
		defer cancel()
		if m == nil {
			return
		}
		known := false
		for _, z := range m.Zones {
			if z.ID == zone {
				known = true
				break
			}
		}
		if !known || start.Before(m.Start) || end.After(m.End) {
			send(w, 400, map[string]string{"error": "zone or period outside the loaded dataset"})
			return
		}
		rows, err := data.Observations(ctx, m.LoadID, zone, start.UTC(), end.UTC())
		if err != nil {
			send(w, 503, map[string]string{"error": "observations unavailable"})
			return
		}
		send(w, 200, map[string]any{"dataset_id": m.ID, "timezone": m.Timezone, "indicator": "accepted_completed_trips", "windows": rows})
	})
	if len(options) > 0 && options[0].Runtime != nil {
		attach(mux, options[0])
		if options[0].Auth != nil {
			options[0].Auth.routes(mux)
			attachStream(mux, options[0])
			return options[0].Auth.wrap(mux)
		}
	}
	return mux
}

func send(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
