package ml

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/rand"
	"os"
	"sort"
	"time"

	"github.com/proyecto-g7/transporte/internal/features"
)

type Config struct {
	Epochs             int     `json:"epochs"`
	BatchSize          int     `json:"batch_size"`
	LearningRate       float64 `json:"learning_rate"`
	L2                 float64 `json:"l2"`
	Seed               int64   `json:"seed"`
	Workers            int     `json:"workers"`
	TaskTimeoutSeconds int     `json:"task_timeout_seconds"`
}

func (c Config) Validate() error {
	if c.Epochs < 1 || c.Epochs > 200 || c.BatchSize < 4 || c.BatchSize > 65536 || c.Workers < 1 || c.Workers > 16 || c.BatchSize < c.Workers {
		return fmt.Errorf("invalid epochs, batch_size or workers")
	}
	if !Finite(c.LearningRate) || c.LearningRate <= 0 || c.LearningRate > 1 || !Finite(c.L2) || c.L2 < 0 || c.L2 > 1 {
		return fmt.Errorf("invalid learning_rate or l2")
	}
	if c.TaskTimeoutSeconds < 1 || c.TaskTimeoutSeconds > 120 {
		return fmt.Errorf("task_timeout_seconds must be 1..120")
	}
	return nil
}
func Finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }

type Encoder struct {
	Zones       []int      `json:"zones"`
	Mean        [3]float64 `json:"mean"`
	Scale       [3]float64 `json:"scale"`
	Version     string     `json:"version"`
	TargetMean  float64    `json:"target_mean,omitempty"`
	TargetScale float64    `json:"target_scale,omitempty"`
}

func (e Encoder) Dimension() int {
	if e.Version == "linear-count-v2" {
		return 2*len(e.Zones) + 12
	}
	return len(e.Zones) + 12
}
func (e Encoder) BiasIndex() int { return len(e.Zones) + 11 }
func (e Encoder) Validate() error {
	if (e.Version != "linear-log-count-v1" && e.Version != "linear-count-v2") || len(e.Zones) == 0 || len(e.Zones) > 263 {
		return fmt.Errorf("invalid encoder schema")
	}
	last := 0
	for _, z := range e.Zones {
		if z <= last || z > 263 {
			return fmt.Errorf("invalid zone vocabulary")
		}
		last = z
	}
	for i := range e.Mean {
		if !Finite(e.Mean[i]) || !Finite(e.Scale[i]) || e.Scale[i] <= 0 {
			return fmt.Errorf("invalid normalizer")
		}
	}
	if e.Version == "linear-count-v2" && (!Finite(e.TargetMean) || !Finite(e.TargetScale) || e.TargetScale <= 0) {
		return fmt.Errorf("invalid target normalizer")
	}
	return nil
}

type Entry struct {
	Index int
	Value float64
}
type Row struct {
	X                       []Entry
	Y                       float64
	Count                   float64
	Lag                     float64
	TargetMean, TargetScale float64
}
type Dataset struct{ Train, Validation, Test []Row }

func ReadSnapshot(ctx context.Context, path, checksum string) ([]features.Example, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := sha256.New()
	d := json.NewDecoder(io.TeeReader(f, h))
	rows := make([]features.Example, 0, 80000)
	var last time.Time
	lastZone := 0
	lastSplit := 0
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var x features.Example
		err := d.Decode(&x)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		if len(rows) >= 2000000 {
			return nil, fmt.Errorf("snapshot row limit exceeded")
		}
		split := map[string]int{"train": 1, "validation": 2, "test": 3}[x.Split]
		if split == 0 || split < lastSplit || x.ZoneID < 1 || x.ZoneID > 263 || x.DayOfWeek < 0 || x.DayOfWeek > 6 || x.Lag1 < 0 || x.Target < 0 || !Finite(x.HourSin) || !Finite(x.HourCos) || math.Abs(x.HourSin) > 1.000001 || math.Abs(x.HourCos) > 1.000001 || x.Origin.IsZero() || !x.TargetStart.Equal(x.Origin) {
			return nil, fmt.Errorf("invalid feature row %d", len(rows)+1)
		}
		if x.Origin.Before(last) || x.Origin.Equal(last) && x.ZoneID <= lastZone {
			return nil, fmt.Errorf("snapshot must have unique rows ordered by time and zone")
		}
		last = x.Origin
		lastZone = x.ZoneID
		lastSplit = split
		rows = append(rows, x)
	}
	if hex.EncodeToString(h.Sum(nil)) != checksum {
		return nil, fmt.Errorf("snapshot checksum mismatch")
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("empty snapshot")
	}
	return rows, nil
}

// Fit uses only train rows, including its categorical vocabulary.
func Fit(rows []features.Example) (Encoder, error) {
	e := Encoder{Version: "linear-count-v2"}
	zones := map[int]bool{}
	n := 0
	var m2 [3]float64
	targetM2 := 0.0
	for _, x := range rows {
		if x.Split != "train" {
			continue
		}
		n++
		zones[x.ZoneID] = true
		v := [3]float64{x.HourSin, x.HourCos, float64(x.Lag1)}
		deltaTarget := float64(x.Target) - e.TargetMean
		e.TargetMean += deltaTarget / float64(n)
		targetM2 += deltaTarget * (float64(x.Target) - e.TargetMean)
		for i := range v {
			delta := v[i] - e.Mean[i]
			e.Mean[i] += delta / float64(n)
			m2[i] += delta * (v[i] - e.Mean[i])
		}
	}
	if n < 2 {
		return e, fmt.Errorf("at least two train examples required")
	}
	for z := range zones {
		e.Zones = append(e.Zones, z)
	}
	sort.Ints(e.Zones)
	for i := range e.Scale {
		e.Scale[i] = math.Sqrt(m2[i] / float64(n))
		if e.Scale[i] < 1e-12 {
			e.Scale[i] = 1
		}
	}
	e.TargetScale = math.Sqrt(targetM2 / float64(n))
	if e.TargetScale < 1e-12 {
		e.TargetScale = 1
	}
	return e, e.Validate()
}
func (e Encoder) Encode(x features.Example) (Row, error) {
	z := sort.SearchInts(e.Zones, x.ZoneID)
	if z == len(e.Zones) || e.Zones[z] != x.ZoneID {
		return Row{}, fmt.Errorf("unknown model zone %d", x.ZoneID)
	}
	if x.DayOfWeek < 0 || x.DayOfWeek > 6 || x.Lag1 < 0 || x.Target < 0 || !Finite(x.HourSin) || !Finite(x.HourCos) {
		return Row{}, fmt.Errorf("invalid input features")
	}
	b := len(e.Zones)
	weekend := 0.0
	if x.Weekend {
		weekend = 1
	}
	lag, target := math.Log1p(float64(x.Lag1)), math.Log1p(float64(x.Target))
	if e.Version == "linear-count-v2" {
		lag = float64(x.Lag1)
		target = (float64(x.Target) - e.TargetMean) / e.TargetScale
	}
	r := Row{X: []Entry{{z, 1}, {b + x.DayOfWeek, 1}, {b + 7, (x.HourSin - e.Mean[0]) / e.Scale[0]}, {b + 8, (x.HourCos - e.Mean[1]) / e.Scale[1]}, {b + 9, weekend}, {b + 10, (lag - e.Mean[2]) / e.Scale[2]}, {b + 11, 1}}, Y: target, Count: float64(x.Target), Lag: float64(x.Lag1)}
	if e.Version == "linear-count-v2" {
		r.X = append(r.X, Entry{b + 12 + z, (lag - e.Mean[2]) / e.Scale[2]})
		r.TargetMean = e.TargetMean
		r.TargetScale = e.TargetScale
	}
	for _, p := range r.X {
		if !Finite(p.Value) {
			return Row{}, fmt.Errorf("non-finite encoded feature")
		}
	}
	return r, nil
}
func Prepare(rows []features.Example, e Encoder) (Dataset, error) {
	if err := e.Validate(); err != nil {
		return Dataset{}, err
	}
	var d Dataset
	for _, x := range rows {
		r, err := e.Encode(x)
		if err != nil {
			return d, err
		}
		switch x.Split {
		case "train":
			d.Train = append(d.Train, r)
		case "validation":
			d.Validation = append(d.Validation, r)
		case "test":
			d.Test = append(d.Test, r)
		default:
			return d, fmt.Errorf("invalid split")
		}
	}
	if len(d.Train) == 0 || len(d.Validation) == 0 || len(d.Test) == 0 {
		return d, fmt.Errorf("train, validation and test must be nonempty")
	}
	return d, nil
}
func Initial(e Encoder) []float64 {
	w := make([]float64, e.Dimension())
	w[len(e.Zones)+10] = e.Scale[2]
	w[e.BiasIndex()] = e.Mean[2]
	if e.Version == "linear-count-v2" {
		w[len(e.Zones)+10] /= e.TargetScale
		w[e.BiasIndex()] = (e.Mean[2] - e.TargetMean) / e.TargetScale
	}
	return w
}
func RawPrediction(weights []float64, r Row) float64 {
	v := 0.0
	for _, x := range r.X {
		v += weights[x.Index] * x.Value
	}
	return v
}
func Predict(weights []float64, r Row) (float64, error) {
	for _, x := range r.X {
		if x.Index < 0 || x.Index >= len(weights) {
			return 0, fmt.Errorf("model dimension mismatch")
		}
	}
	v := math.Expm1(RawPrediction(weights, r))
	if r.TargetScale > 0 {
		v = RawPrediction(weights, r)*r.TargetScale + r.TargetMean
	}
	if !Finite(v) {
		return 0, fmt.Errorf("non-finite prediction")
	}
	return math.Max(0, v), nil
}

type Gradient struct {
	Sum     []float64 `json:"sum"`
	Count   int       `json:"count"`
	LossSum float64   `json:"loss_sum"`
}
type Computer func(context.Context, int, []float64, []int) (Gradient, error)

func Compute(ctx context.Context, rows []Row, weights []float64, indices []int) (Gradient, error) {
	g := Gradient{Sum: make([]float64, len(weights)), Count: len(indices)}
	for _, index := range indices {
		if err := ctx.Err(); err != nil {
			return g, err
		}
		if index < 0 || index >= len(rows) {
			return g, fmt.Errorf("invalid batch index")
		}
		r := rows[index]
		v := RawPrediction(weights, r) - r.Y
		if !Finite(v) {
			return g, fmt.Errorf("non-finite loss")
		}
		g.LossSum += 0.5 * v * v
		for _, p := range r.X {
			g.Sum[p.Index] += v * p.Value
		}
	}
	return g, nil
}
func ValidateGradient(g Gradient, dimension, count int) error {
	if len(g.Sum) != dimension || g.Count != count || count <= 0 || !Finite(g.LossSum) || g.LossSum < 0 {
		return fmt.Errorf("invalid gradient shape/count/loss")
	}
	for _, v := range g.Sum {
		if !Finite(v) {
			return fmt.Errorf("non-finite gradient")
		}
	}
	return nil
}

type Progress struct {
	Epoch      int     `json:"epoch"`
	Step       int     `json:"step"`
	TotalSteps int     `json:"total_steps"`
	Loss       float64 `json:"objective_loss"`
}

func Train(ctx context.Context, rows []Row, e Encoder, c Config, compute Computer, progress func(Progress)) ([]float64, []float64, error) {
	if err := c.Validate(); err != nil {
		return nil, nil, err
	}
	if len(rows) == 0 {
		return nil, nil, fmt.Errorf("no training rows")
	}
	w := Initial(e)
	rng := rand.New(rand.NewSource(c.Seed))
	indices := make([]int, len(rows))
	for i := range indices {
		indices[i] = i
	}
	total := c.Epochs * ((len(rows) + c.BatchSize - 1) / c.BatchSize)
	step := 0
	history := make([]float64, 0, c.Epochs)
	for epoch := 1; epoch <= c.Epochs; epoch++ {
		rng.Shuffle(len(indices), func(i, j int) { indices[i], indices[j] = indices[j], indices[i] })
		loss := 0.0
		for start := 0; start < len(indices); start += c.BatchSize {
			end := min(start+c.BatchSize, len(indices))
			batch := indices[start:end]
			g, err := compute(ctx, step, w, batch)
			if err != nil {
				return nil, history, err
			}
			if err := ValidateGradient(g, len(w), len(batch)); err != nil {
				return nil, history, err
			}
			loss += g.LossSum
			for i := range w {
				regularizer := c.L2 * w[i]
				if i == e.BiasIndex() {
					regularizer = 0
				}
				w[i] -= c.LearningRate * (g.Sum[i]/float64(g.Count) + regularizer)
				if !Finite(w[i]) {
					return nil, history, fmt.Errorf("non-finite model update")
				}
			}
			step++
			if progress != nil {
				progress(Progress{Epoch: epoch, Step: step, TotalSteps: total, Loss: g.LossSum / float64(g.Count)})
			}
		}
		history = append(history, loss/float64(len(rows)))
	}
	return w, history, nil
}

type Metrics struct {
	Examples      int     `json:"examples"`
	MAE           float64 `json:"mae"`
	RMSE          float64 `json:"rmse"`
	LogLoss       float64 `json:"log_loss"`
	ObjectiveLoss float64 `json:"objective_loss"`
}
type Evaluation struct {
	Model               Metrics `json:"model"`
	PersistenceBaseline Metrics `json:"persistence_baseline"`
}

func Evaluate(rows []Row, weights []float64) (Evaluation, error) {
	var e Evaluation
	e.Model.Examples = len(rows)
	e.PersistenceBaseline.Examples = len(rows)
	if len(rows) == 0 {
		return e, fmt.Errorf("empty evaluation split")
	}
	for _, r := range rows {
		p, err := Predict(weights, r)
		if err != nil {
			return e, err
		}
		a, b := p-r.Count, r.Lag-r.Count
		e.Model.MAE += math.Abs(a)
		e.Model.RMSE += a * a
		e.PersistenceBaseline.MAE += math.Abs(b)
		e.PersistenceBaseline.RMSE += b * b
		v := RawPrediction(weights, r) - r.Y
		e.Model.ObjectiveLoss += 0.5 * v * v
		baselineY := math.Log1p(r.Lag)
		if r.TargetScale > 0 {
			baselineY = (r.Lag - r.TargetMean) / r.TargetScale
		}
		v = baselineY - r.Y
		e.PersistenceBaseline.ObjectiveLoss += 0.5 * v * v
		v = math.Log1p(p) - math.Log1p(r.Count)
		e.Model.LogLoss += 0.5 * v * v
		v = math.Log1p(r.Lag) - math.Log1p(r.Count)
		e.PersistenceBaseline.LogLoss += 0.5 * v * v
	}
	n := float64(len(rows))
	e.Model.MAE /= n
	e.Model.RMSE = math.Sqrt(e.Model.RMSE / n)
	e.Model.LogLoss /= n
	e.PersistenceBaseline.MAE /= n
	e.PersistenceBaseline.RMSE = math.Sqrt(e.PersistenceBaseline.RMSE / n)
	e.PersistenceBaseline.LogLoss /= n
	e.Model.ObjectiveLoss /= n
	e.PersistenceBaseline.ObjectiveLoss /= n
	return e, nil
}
