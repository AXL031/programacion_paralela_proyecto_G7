package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/ml"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

type Options struct {
	Runtime        *Runtime
	MasterURL      string
	TrainingConfig ml.Config
	Auth           *Auth
	MasterToken    string
	Context        context.Context
}

func attach(mux *http.ServeMux, o Options) {
	attachImpact(mux, o.Runtime)
	mux.HandleFunc("GET /api/v1/models/current", func(w http.ResponseWriter, r *http.Request) { send(w, 200, o.Runtime.Metadata()) })
	mux.HandleFunc("POST /api/v1/predictions", func(w http.ResponseWriter, r *http.Request) {
		var input PredictionRequest
		if err := decode(w, r, &input); err != nil {
			send(w, 400, map[string]string{"error": "Solicitud inválida: usa una zona y una fecha con zona horaria."})
			return
		}
		prediction, err := o.Runtime.Predict(r.Context(), input)
		if err != nil {
			var request RequestError
			if errors.As(err, &request) {
				send(w, request.Status, map[string]string{"error": request.Message})
			} else {
				send(w, 503, map[string]string{"error": "No se pudo calcular la predicción."})
			}
			return
		}
		send(w, 200, prediction)
	})
	mux.HandleFunc("GET /api/v1/training-config", func(w http.ResponseWriter, r *http.Request) { send(w, 200, o.TrainingConfig) })
	proxy := func(w http.ResponseWriter, r *http.Request, method, path string, body any) {
		var payload []byte
		if body != nil {
			payload, _ = json.Marshal(body)
		}
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(o.MasterURL, "/")+path, bytes.NewReader(payload))
		if err != nil {
			send(w, 503, map[string]string{"error": "Coordinador no disponible."})
			return
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+o.MasterToken)
		response, err := (&http.Client{Timeout: 8 * time.Second}).Do(req)
		if err != nil {
			send(w, 503, map[string]string{"error": "El coordinador del clúster no responde. Las consultas siguen disponibles."})
			return
		}
		defer response.Body.Close()
		raw, err := io.ReadAll(io.LimitReader(response.Body, 2*1024*1024))
		if err != nil || !json.Valid(raw) {
			send(w, 503, map[string]string{"error": "Respuesta inválida del coordinador."})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(response.StatusCode)
		w.Write(raw)
	}
	mux.HandleFunc("GET /api/v1/cluster", func(w http.ResponseWriter, r *http.Request) { proxy(w, r, "GET", "/cluster", nil) })
	mux.HandleFunc("POST /api/v1/training-runs", func(w http.ResponseWriter, r *http.Request) {
		var c ml.Config
		if err := decode(w, r, &c); err != nil {
			send(w, 400, map[string]string{"error": "Configuración de entrenamiento inválida."})
			return
		}
		if err := c.Validate(); err != nil {
			send(w, 400, map[string]string{"error": err.Error()})
			return
		}
		proxy(w, r, "POST", "/runs", c)
	})
	pattern := regexp.MustCompile(`^run-[a-f0-9]{24}$`)
	mux.HandleFunc("GET /api/v1/training-runs/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if !pattern.MatchString(id) {
			send(w, 400, map[string]string{"error": "Identificador de entrenamiento inválido."})
			return
		}
		proxy(w, r, "GET", "/runs/"+id, nil)
	})
}
func decode(w http.ResponseWriter, r *http.Request, v any) error {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	if err := d.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("one JSON object required")
	}
	return nil
}
