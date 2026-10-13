package ml

import (
	"context"
	"encoding/json"
	"github.com/proyecto-g7/transporte/internal/features"
	"math"
	"testing"
)

func rawRows() []features.Example {
	var rows []features.Example
	for i := 0; i < 240; i++ {
		split := "train"
		if i >= 180 {
			split = "test"
		} else if i >= 160 {
			split = "validation"
		}
		lag := int64(i%12 + 1)
		rows = append(rows, features.Example{ZoneID: 161 + i%2, HourSin: math.Sin(float64(i)), HourCos: math.Cos(float64(i)), DayOfWeek: i % 7, Lag1: lag, Target: lag * 2, Split: split})
	}
	return rows
}
func TestNormalizerUsesTrainOnly(t *testing.T) {
	rows := rawRows()
	a, err := Fit(rows)
	if err != nil {
		t.Fatal(err)
	}
	for i := range rows {
		if rows[i].Split != "train" {
			rows[i].Lag1 = 90000000
			rows[i].Target = 80000000
			rows[i].ZoneID = 263
			rows[i].HourSin = -0.9
		}
	}
	b, err := Fit(rows)
	if err != nil {
		t.Fatal(err)
	}
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	if string(x) != string(y) {
		t.Fatal("validation/test influenced normalizer or vocabulary")
	}
}
func TestGradientAgainstFiniteDifferences(t *testing.T) {
	rows := rawRows()
	e, err := Fit(rows)
	if err != nil {
		t.Fatal(err)
	}
	d, err := Prepare(rows, e)
	if err != nil {
		t.Fatal(err)
	}
	w := Initial(e)
	indices := []int{0, 2, 7, 11, 19}
	g, err := Compute(context.Background(), d.Train, w, indices)
	if err != nil {
		t.Fatal(err)
	}
	const epsilon = 1e-6
	loss := func(weights []float64) float64 {
		v := 0.0
		for _, i := range indices {
			err := RawPrediction(weights, d.Train[i]) - d.Train[i].Y
			v += 0.5 * err * err
		}
		return v
	}
	for i := range w {
		w[i] += epsilon
		plus := loss(w)
		w[i] -= 2 * epsilon
		minus := loss(w)
		w[i] += epsilon
		numeric := (plus - minus) / (2 * epsilon)
		if math.Abs(numeric-g.Sum[i]) > 1e-7 {
			t.Fatalf("gradient %d: numeric=%g computed=%g", i, numeric, g.Sum[i])
		}
	}
}
func TestTrainingConvergenceUnevenReductionAndSerialization(t *testing.T) {
	raw := rawRows()
	e, err := Fit(raw)
	if err != nil {
		t.Fatal(err)
	}
	d, err := Prepare(raw, e)
	if err != nil {
		t.Fatal(err)
	}
	c := Config{Epochs: 12, BatchSize: 31, LearningRate: 0.1, L2: 0.0001, Seed: 42, Workers: 1, TaskTimeoutSeconds: 2}
	local := func(ctx context.Context, _ int, w []float64, ids []int) (Gradient, error) {
		return Compute(ctx, d.Train, w, ids)
	}
	w, history, err := Train(context.Background(), d.Train, e, c, local, nil)
	if err != nil {
		t.Fatal(err)
	}
	if history[len(history)-1] >= history[0] {
		t.Fatal("training loss did not decrease")
	}
	for _, workers := range []int{2, 4} {
		c.Workers = workers
		remote := func(ctx context.Context, _ int, w []float64, ids []int) (Gradient, error) {
			total := Gradient{Sum: make([]float64, len(w))}
			for i := 0; i < workers; i++ {
				part := ids[len(ids)*i/workers : len(ids)*(i+1)/workers]
				if len(part) == 0 {
					continue
				}
				g, err := Compute(ctx, d.Train, w, part)
				if err != nil {
					return total, err
				}
				for j, v := range g.Sum {
					total.Sum[j] += v
				}
				total.Count += g.Count
				total.LossSum += g.LossSum
			}
			return total, nil
		}
		other, _, err := Train(context.Background(), d.Train, e, c, remote, nil)
		if err != nil {
			t.Fatal(err)
		}
		for i := range w {
			if math.Abs(w[i]-other[i]) > 1e-12 {
				t.Fatal("partitioning changed optimizer semantics")
			}
		}
	}
	b, err := json.Marshal(struct {
		Encoder Encoder
		Weights []float64
	}{e, w})
	if err != nil {
		t.Fatal(err)
	}
	var restored struct {
		Encoder Encoder
		Weights []float64
	}
	if err := json.Unmarshal(b, &restored); err != nil {
		t.Fatal(err)
	}
	row, err := restored.Encoder.Encode(raw[len(raw)-1])
	if err != nil {
		t.Fatal(err)
	}
	p, err := Predict(w, row)
	if err != nil {
		t.Fatal(err)
	}
	q, err := Predict(restored.Weights, row)
	if err != nil || p != q {
		t.Fatal("reload changed prediction")
	}
}
func TestBadGradientCannotUpdate(t *testing.T) {
	raw := rawRows()
	e, _ := Fit(raw)
	d, _ := Prepare(raw, e)
	c := Config{Epochs: 1, BatchSize: 8, LearningRate: 0.1, Workers: 1, TaskTimeoutSeconds: 1}
	_, _, err := Train(context.Background(), d.Train, e, c, func(context.Context, int, []float64, []int) (Gradient, error) {
		return Gradient{Count: 8, Sum: []float64{math.NaN()}}, nil
	}, nil)
	if err == nil {
		t.Fatal("invalid gradient accepted")
	}
}
