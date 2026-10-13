package api

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/domain"
	"github.com/proyecto-g7/transporte/internal/features"
	"github.com/proyecto-g7/transporte/internal/ml"
	"github.com/proyecto-g7/transporte/internal/training"
	"math"
	"sync"
	"sync/atomic"
	"time"
)

type ModelData interface {
	Data
	Model(context.Context, string) (training.Artifact, error)
	Windows(context.Context, string) ([]domain.Window, error)
}
type Cache interface {
	Get(context.Context, string) (string, error)
	Set(context.Context, string, string, time.Duration) error
}
type windowKey struct {
	zone int
	unix int64
}
type bundle struct {
	Model    training.Artifact
	Dataset  domain.Manifest
	counts   map[windowKey]int64
	location *time.Location
}
type Runtime struct {
	data      ModelData
	cache     Cache
	current   atomic.Pointer[bundle]
	refresh   sync.Mutex
	lastError atomic.Value
}

func NewRuntime(data ModelData, cache Cache) *Runtime {
	r := &Runtime{data: data, cache: cache}
	r.lastError.Store("")
	return r
}
func (r *Runtime) Start(ctx context.Context) {
	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		for {
			c, cancel := context.WithTimeout(ctx, 15*time.Second)
			err := r.Refresh(c)
			cancel()
			if err != nil {
				r.lastError.Store(err.Error())
			} else {
				r.lastError.Store("")
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
}
func (r *Runtime) Refresh(ctx context.Context) error {
	r.refresh.Lock()
	defer r.refresh.Unlock()
	m, err := r.data.Current(ctx)
	if err != nil {
		return err
	}
	if m == nil {
		return fmt.Errorf("no dataset")
	}
	a, err := r.data.Model(ctx, "current")
	if err != nil {
		return err
	}
	if err := a.Validate(); err != nil {
		return err
	}
	if a.DatasetID != m.ID || a.SnapshotSHA256 != m.Snapshot.SHA256 || a.WindowMinutes != m.WindowMinutes || a.Timezone != m.Timezone {
		return fmt.Errorf("model does not match current dataset")
	}
	previous := r.current.Load()
	if previous != nil && previous.Model.Version == a.Version && previous.Dataset.LoadID == m.LoadID {
		return nil
	}
	if previous != nil && previous.Dataset.LoadID == m.LoadID && previous.Dataset.ID == m.ID {
		r.current.Store(&bundle{a, *m, previous.counts, previous.location})
		return nil
	}
	rows, err := r.data.Windows(ctx, m.LoadID)
	if err != nil {
		return err
	}
	if int64(len(rows)) != m.Snapshot.Windows {
		return fmt.Errorf("incomplete observation grid")
	}
	loc, err := time.LoadLocation(m.Timezone)
	if err != nil {
		return err
	}
	counts := make(map[windowKey]int64, len(rows))
	step := int64(m.WindowMinutes * 60)
	for _, w := range rows {
		key := windowKey{w.ZoneID, w.Start.Unix()}
		if w.LoadID != m.LoadID || w.Count < 0 || w.Start.Before(m.Start) || !w.Start.Before(m.End) || w.Start.Unix()%step != 0 {
			return fmt.Errorf("invalid observation grid")
		}
		if _, ok := counts[key]; ok {
			return fmt.Errorf("duplicate observation window")
		}
		counts[key] = w.Count
	}
	r.current.Store(&bundle{a, *m, counts, loc})
	return nil
}

type PredictionRequest struct {
	DatasetID string    `json:"dataset_id"`
	ZoneID    int       `json:"zone_id"`
	Origin    time.Time `json:"forecast_origin"`
	Horizon   int       `json:"horizon_minutes"`
}
type Prediction struct {
	DatasetID string    `json:"dataset_id"`
	ZoneID    int       `json:"zone_id"`
	Origin    time.Time `json:"forecast_origin"`
	Horizon   int       `json:"horizon_minutes"`
	Predicted float64   `json:"predicted_observed_trips"`
	Previous  int64     `json:"previous_observed_trips"`
	Actual    int64     `json:"actual_observed_trips"`
	Version   string    `json:"model_version"`
	Method    string    `json:"method"`
	Split     string    `json:"evaluation_period"`
	CacheHit  bool      `json:"cache_hit"`
	LatencyMS float64   `json:"latency_ms"`
}
type RequestError struct {
	Status  int
	Message string
}

func (e RequestError) Error() string { return e.Message }
func (r *Runtime) Predict(ctx context.Context, input PredictionRequest) (Prediction, error) {
	started := time.Now()
	if input.DatasetID == "" || input.ZoneID < 1 || input.ZoneID > 263 || input.Origin.IsZero() || input.Horizon < 1 {
		return Prediction{}, RequestError{400, "Completa dataset, zona, fecha y horizonte de la consulta."}
	}
	b := r.current.Load()
	if b == nil {
		return Prediction{}, RequestError{503, "Todavía no hay un modelo listo para consultar."}
	}
	if input.DatasetID != b.Dataset.ID {
		return Prediction{}, RequestError{409, "El modelo no corresponde al dataset solicitado. Entrena con los datos actuales."}
	}
	step := time.Duration(b.Dataset.WindowMinutes) * time.Minute
	if input.Horizon != b.Dataset.WindowMinutes || input.Origin.Nanosecond() != 0 || input.Origin.Unix()%int64(step.Seconds()) != 0 || input.Origin.Before(b.Dataset.Start.Add(step)) || input.Origin.Add(step).After(b.Dataset.End) {
		return Prediction{}, RequestError{400, "Selecciona un intervalo de 15 minutos dentro del histórico disponible."}
	}
	lag, ok := b.counts[windowKey{input.ZoneID, input.Origin.Add(-step).Unix()}]
	if !ok {
		return Prediction{}, RequestError{400, "La zona o su intervalo anterior no están disponibles."}
	}
	actual, ok := b.counts[windowKey{input.ZoneID, input.Origin.Unix()}]
	if !ok {
		return Prediction{}, RequestError{400, "El intervalo no está disponible."}
	}
	key := fmt.Sprintf("prediction:%s:%s:%s:%d:%d:%d", b.Model.Version, b.Model.SnapshotSHA256, b.Dataset.LoadID, input.ZoneID, input.Origin.Unix(), input.Horizon)
	cacheAvailable := r.cache != nil
	if r.cache != nil {
		c, cancel := context.WithTimeout(ctx, 30*time.Millisecond)
		raw, err := r.cache.Get(c, key)
		cancel()
		cacheAvailable = err == nil
		if err == nil {
			var p Prediction
			if json.Unmarshal([]byte(raw), &p) == nil && p.Version == b.Model.Version && p.DatasetID == input.DatasetID && p.ZoneID == input.ZoneID && p.Origin.Equal(input.Origin) && p.Horizon == input.Horizon && p.Previous == lag && p.Actual == actual && p.Predicted >= 0 && ml.Finite(p.Predicted) {
				p.CacheHit = true
				p.LatencyMS = float64(time.Since(started).Microseconds()) / 1000
				return p, nil
			}
		}
	}
	local := input.Origin.In(b.location)
	fraction := (float64(local.Hour()) + float64(local.Minute())/60) / 24
	x := features.Example{ZoneID: input.ZoneID, Origin: input.Origin, TargetStart: input.Origin, HourSin: math.Sin(2 * math.Pi * fraction), HourCos: math.Cos(2 * math.Pi * fraction), DayOfWeek: int(local.Weekday()), Weekend: local.Weekday() == time.Saturday || local.Weekday() == time.Sunday, Lag1: lag}
	row, err := b.Model.Encoder.Encode(x)
	if err != nil {
		return Prediction{}, RequestError{400, "Esta zona no pertenece al modelo entrenado."}
	}
	value, err := ml.Predict(b.Model.Weights, row)
	if err != nil {
		return Prediction{}, err
	}
	split := "test"
	if input.Origin.Before(b.Model.TrainEnd) {
		split = "train"
	} else if input.Origin.Before(b.Model.ValidationEnd) {
		split = "validation"
	}
	method := b.Model.Selection.Method
	if method == "" {
		method = "legacy_sgd"
	}
	p := Prediction{DatasetID: input.DatasetID, ZoneID: input.ZoneID, Origin: input.Origin.UTC(), Horizon: input.Horizon, Predicted: value, Previous: lag, Actual: actual, Version: b.Model.Version, Method: method, Split: split}
	if cacheAvailable {
		raw, _ := json.Marshal(p)
		c, cancel := context.WithTimeout(ctx, 30*time.Millisecond)
		r.cache.Set(c, key, string(raw), time.Hour)
		cancel()
	}
	p.LatencyMS = float64(time.Since(started).Microseconds()) / 1000
	return p, nil
}
func (r *Runtime) Metadata() map[string]any {
	b := r.current.Load()
	if b == nil {
		return map[string]any{"ready": false}
	}
	return map[string]any{"ready": true, "version": b.Model.Version, "dataset_id": b.Model.DatasetID, "method": b.Model.Selection.Method, "created_at": b.Model.CreatedAt, "evaluation": b.Model.Evaluation, "selection": b.Model.Selection, "train_end": b.Model.TrainEnd, "validation_end": b.Model.ValidationEnd, "first_origin": b.Dataset.Start.Add(time.Duration(b.Dataset.WindowMinutes) * time.Minute), "last_origin": b.Dataset.End.Add(-time.Duration(b.Dataset.WindowMinutes) * time.Minute), "horizon_minutes": b.Dataset.WindowMinutes, "timezone": b.Dataset.Timezone, "refresh_degraded": r.lastError.Load() != ""}
}
