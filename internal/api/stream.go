package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

type streamRequest struct {
	Type    string            `json:"type"`
	ID      string            `json:"request_id,omitempty"`
	RunID   string            `json:"run_id,omitempty"`
	Request PredictionRequest `json:"request,omitempty"`
}

func attachStream(mux *http.ServeMux, o Options) {
	var connected atomic.Int32
	client := &http.Client{Timeout: 2 * time.Second}
	fetch := func(ctx context.Context, path string) (json.RawMessage, error) {
		req, err := http.NewRequestWithContext(ctx, "GET", o.MasterURL+path, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+o.MasterToken)
		res, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer res.Body.Close()
		var raw json.RawMessage
		err = json.NewDecoder(io.LimitReader(res.Body, 2*1024*1024)).Decode(&raw)
		if res.StatusCode != 200 {
			return nil, fmt.Errorf("coordinator status %d", res.StatusCode)
		}
		return raw, err
	}
	mux.HandleFunc("GET /api/v1/events", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Origin") != o.Auth.origin {
			send(w, 403, map[string]string{"error": "Origen no permitido."})
			return
		}
		if connected.Add(1) > 32 {
			connected.Add(-1)
			send(w, 503, map[string]string{"error": "Demasiadas conexiones."})
			return
		}
		defer connected.Add(-1)
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		c.SetReadLimit(8192)
		claims := r.Context().Value(identityKey{}).(*Claims)
		parent := o.Context
		if parent == nil {
			parent = context.Background()
		}
		ctx, cancel := context.WithDeadline(parent, claims.ExpiresAt.Time)
		defer cancel()
		requests := make(chan streamRequest, 8)
		go func() {
			defer cancel()
			for {
				var input streamRequest
				if err := wsjson.Read(ctx, c, &input); err != nil {
					return
				}
				select {
				case requests <- input:
				case <-ctx.Done():
					return
				}
			}
		}()
		write := func(v any) bool {
			writeCtx, done := context.WithTimeout(ctx, 2*time.Second)
			defer done()
			return wsjson.Write(writeCtx, c, v) == nil
		}
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		runID := ""
		seq := 0
		snapshot := func() bool {
			if !o.Auth.active(claims) {
				c.Close(websocket.StatusPolicyViolation, "session ended")
				return false
			}
			callCtx, done := context.WithTimeout(ctx, 2*time.Second)
			defer done()
			cluster, err := fetch(callCtx, "/cluster")
			var active struct {
				RunID string `json:"active_run"`
			}
			if err == nil {
				json.Unmarshal(cluster, &active)
				if active.RunID != "" {
					runID = active.RunID
				}
			}
			var run json.RawMessage
			if runID != "" {
				run, _ = fetch(callCtx, "/runs/"+runID)
			}
			seq++
			return write(map[string]any{"type": "snapshot", "sequence": seq, "at": time.Now().UTC(), "cluster": cluster, "cluster_available": err == nil, "run": run, "model": o.Runtime.Metadata()})
		}
		if !snapshot() {
			return
		}
		for {
			select {
			case <-ctx.Done():
				c.Close(websocket.StatusPolicyViolation, "session ended")
				return
			case <-ticker.C:
				if !snapshot() {
					return
				}
			case input := <-requests:
				if !o.Auth.active(claims) {
					c.Close(websocket.StatusPolicyViolation, "session ended")
					return
				}
				switch input.Type {
				case "watch":
					if !regexp.MustCompile(`^run-[a-f0-9]{24}$`).MatchString(input.RunID) {
						if !write(map[string]any{"type": "error", "error": "Entrenamiento inválido."}) {
							return
						}
						continue
					}
					runID = input.RunID
				case "predict":
					if len(input.ID) > 128 {
						c.Close(websocket.StatusPolicyViolation, "invalid request id")
						return
					}
					prediction, err := o.Runtime.Predict(ctx, input.Request)
					if err != nil {
						if !write(map[string]any{"type": "prediction", "request_id": input.ID, "error": err.Error()}) {
							return
						}
					} else {
						if !write(map[string]any{"type": "prediction", "request_id": input.ID, "prediction": prediction}) {
							return
						}
					}
				default:
					if !write(map[string]any{"type": "error", "error": "Evento no admitido."}) {
						return
					}
				}
			}
		}
	})
}
