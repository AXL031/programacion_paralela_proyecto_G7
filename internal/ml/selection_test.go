package ml

import (
	"context"
	"math"
	"testing"
)

func TestValidationRejectsInferiorCandidate(t *testing.T) {
	raw := rawRows()
	e, _ := Fit(raw)
	d, _ := Prepare(raw, e)
	bad := Initial(e)
	bad[e.BiasIndex()] += 100
	selected, policy, err := Select(d.Validation, e, bad)
	if err != nil || policy.Method != "persistence" {
		t.Fatal("inferior candidate selected")
	}
	for i, w := range selected {
		if w != Initial(e)[i] {
			t.Fatal("baseline not preserved")
		}
	}
}
func TestSelectionDoesNotDependOnTest(t *testing.T) {
	raw := rawRows()
	e, _ := Fit(raw)
	d, _ := Prepare(raw, e)
	c := Config{Epochs: 3, BatchSize: 31, LearningRate: 0.1, Workers: 1, TaskTimeoutSeconds: 2}
	w, _, _ := Train(context.Background(), d.Train, e, c, func(ctx context.Context, _ int, w []float64, i []int) (Gradient, error) {
		return Compute(ctx, d.Train, w, i)
	}, nil)
	a, _, _ := Select(d.Validation, e, w)
	for i := range d.Test {
		d.Test[i].Count = 90000000
	}
	b, _, _ := Select(d.Validation, e, w)
	for i := range a {
		if math.Abs(a[i]-b[i]) > 1e-15 {
			t.Fatal("test affected selection")
		}
	}
}
