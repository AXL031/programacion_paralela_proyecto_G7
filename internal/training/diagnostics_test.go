package training

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/proyecto-g7/transporte/internal/features"
	"github.com/proyecto-g7/transporte/internal/ml"
)

func syntheticRows() []features.Example {
	var rows []features.Example
	for i := 0; i < 240; i++ {
		split := "train"
		if i >= 180 {
			split = "test"
		} else if i >= 160 {
			split = "validation"
		}
		lag := int64(i%12 + 1)
		rows = append(rows, features.Example{
			ZoneID:    161 + i%2,
			HourSin:   math.Sin(float64(i)),
			HourCos:   math.Cos(float64(i)),
			DayOfWeek: i % 7,
			Lag1:      lag,
			Target:    lag * 2,
			Split:     split,
		})
	}
	return rows
}

func candidateFixture(t *testing.T, weights []float64, validation ml.Metrics) Candidate {
	t.Helper()
	rows := syntheticRows()
	encoder, err := ml.Fit(rows)
	if err != nil {
		t.Fatal(err)
	}
	data, err := ml.Prepare(rows, encoder)
	if err != nil {
		t.Fatal(err)
	}
	if len(weights) != encoder.Dimension() {
		t.Fatalf("fixture weights %d != dimension %d", len(weights), encoder.Dimension())
	}
	return Candidate{
		RunID:              "run-test",
		Mode:               "sequential",
		DatasetID:          "ds-test",
		SnapshotSHA256:     strings.Repeat("a", 64),
		Encoder:            encoder,
		Config:             ml.Config{Epochs: 3, BatchSize: 31, LearningRate: 0.1, L2: 0, Seed: 42, Workers: 1, TaskTimeoutSeconds: 2},
		Seed:               42,
		TrainExamples:      len(data.Train),
		ValidationExamples: len(data.Validation),
		TestExamples:       len(data.Test),
		Dimension:          encoder.Dimension(),
		TotalSteps:         3 * ((len(data.Train) + 30) / 31),
		Weights:            append([]float64{}, weights...),
		Validation:         validation,
		Selection:          ml.Selection{Method: "persistence"},
		LossHistory:        []float64{1.5, 1.0, 0.5},
		CreatedAt:          time.Now().UTC(),
	}
}

func TestCompareWeightsTolerance(t *testing.T) {
	for _, tc := range []struct {
		name      string
		reference []float64
		candidate []float64
		absolute  float64
		relative  float64
		want      bool
		wantMax   float64
	}{
		{name: "identical", reference: []float64{0, 1, -2}, candidate: []float64{0, 1, -2}, absolute: 1e-9, relative: 1e-9, want: true},
		{name: "within absolute", reference: []float64{1}, candidate: []float64{1 + 5e-10}, absolute: 1e-9, relative: 0, want: true, wantMax: 5e-10},
		{name: "outside absolute", reference: []float64{1}, candidate: []float64{1 + 2e-9}, absolute: 1e-9, relative: 0, want: false, wantMax: 2e-9},
		{name: "relative scales", reference: []float64{1e6}, candidate: []float64{1e6 + 1e-4}, absolute: 1e-9, relative: 1e-9, want: true, wantMax: 1e-4},
		{name: "outside relative", reference: []float64{1e6}, candidate: []float64{1e6 + 2e-3}, absolute: 1e-9, relative: 1e-9, want: false, wantMax: 2e-3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			maxDifference, equivalent, err := CompareWeights(tc.reference, tc.candidate, tc.absolute, tc.relative)
			if err != nil {
				t.Fatal(err)
			}
			if equivalent != tc.want {
				t.Fatalf("equivalent=%v, want %v", equivalent, tc.want)
			}
			if tc.wantMax != 0 && math.Abs(maxDifference-tc.wantMax) > tc.wantMax*1e-6 {
				t.Fatalf("max difference %g, want %g", maxDifference, tc.wantMax)
			}
		})
	}
	for _, tc := range []struct {
		name      string
		reference []float64
		candidate []float64
	}{
		{name: "different dimensions", reference: []float64{1}, candidate: []float64{1, 2}},
		{name: "empty", reference: nil, candidate: nil},
		{name: "non-finite", reference: []float64{math.NaN()}, candidate: []float64{1}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, _, err := CompareWeights(tc.reference, tc.candidate, 1e-9, 1e-9); err == nil {
				t.Fatal("invalid weights were accepted")
			}
		})
	}
}

func TestPersistenceCannotHideCandidateDivergence(t *testing.T) {
	rows := syntheticRows()
	encoder, err := ml.Fit(rows)
	if err != nil {
		t.Fatal(err)
	}
	data, err := ml.Prepare(rows, encoder)
	if err != nil {
		t.Fatal(err)
	}
	base := ml.Initial(encoder)
	candidateA := append([]float64{}, base...)
	candidateB := append([]float64{}, base...)
	candidateB[encoder.BiasIndex()] += 50
	selectedA, selectionA, err := ml.Select(data.Validation, encoder, candidateA)
	if err != nil {
		t.Fatal(err)
	}
	selectedB, selectionB, err := ml.Select(data.Validation, encoder, candidateB)
	if err != nil {
		t.Fatal(err)
	}
	if selectionA.Method != "persistence" || selectionB.Method != "persistence" {
		t.Fatalf("fixture must select persistence, got %q and %q", selectionA.Method, selectionB.Method)
	}
	for i := range selectedA {
		if selectedA[i] != selectedB[i] {
			t.Fatal("fixture published weights differ; divergence would already be visible")
		}
	}
	reference, err := NewDiagnostics(candidateFixture(t, candidateA, selectionA.CandidateValidation), "sample-a")
	if err != nil {
		t.Fatal(err)
	}
	if err := reference.SetSelfReference(1e-9, 1e-9); err != nil {
		t.Fatal(err)
	}
	candidate, err := NewDiagnostics(candidateFixture(t, candidateB, selectionB.CandidateValidation), "sample-b")
	if err != nil {
		t.Fatal(err)
	}
	if err := candidate.SetReference(reference, 1e-9, 1e-9); err != nil {
		t.Fatal(err)
	}
	if candidate.Equivalent {
		t.Fatal("identical published persistence hidden a real candidate divergence")
	}
	if candidate.CandidateMaxDifference < 49 {
		t.Fatalf("candidate maximum difference was not recorded: %g", candidate.CandidateMaxDifference)
	}
}

func TestDiagnosticsReferenceCompatibility(t *testing.T) {
	rows := syntheticRows()
	encoder, err := ml.Fit(rows)
	if err != nil {
		t.Fatal(err)
	}
	data, err := ml.Prepare(rows, encoder)
	if err != nil {
		t.Fatal(err)
	}
	metrics := ml.Metrics{Examples: len(data.Validation)}
	candidate := candidateFixture(t, ml.Initial(encoder), metrics)
	reference, err := NewDiagnostics(candidate, "sample-a")
	if err != nil {
		t.Fatal(err)
	}
	if err := reference.SetSelfReference(1e-9, 1e-9); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		mutate func(*Diagnostics)
		want   string
	}{
		{name: "snapshot", mutate: func(d *Diagnostics) { d.SnapshotSHA256 = strings.Repeat("b", 64) }, want: "snapshot"},
		{name: "seed", mutate: func(d *Diagnostics) { d.Seed = 7 }, want: "seed"},
		{name: "splits", mutate: func(d *Diagnostics) { d.TrainExamples++ }, want: "splits"},
		{name: "encoder", mutate: func(d *Diagnostics) { d.EncoderSHA256 = strings.Repeat("c", 64) }, want: "encoder"},
		{name: "dimension", mutate: func(d *Diagnostics) { d.CandidateWeights = d.CandidateWeights[:len(d.CandidateWeights)-1] }, want: "dimension"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			altered := reference
			tc.mutate(&altered)
			diagnostics, err := NewDiagnostics(candidate, "sample-b")
			if err != nil {
				t.Fatal(err)
			}
			if err := diagnostics.SetReference(altered, 1e-9, 1e-9); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("expected %q incompatibility, got %v", tc.want, err)
			}
		})
	}
}

func TestDiagnosticsRoundTripAndIntegrity(t *testing.T) {
	rows := syntheticRows()
	encoder, err := ml.Fit(rows)
	if err != nil {
		t.Fatal(err)
	}
	data, err := ml.Prepare(rows, encoder)
	if err != nil {
		t.Fatal(err)
	}
	candidate := candidateFixture(t, ml.Initial(encoder), ml.Metrics{Examples: len(data.Validation)})
	diagnostics, err := NewDiagnostics(candidate, "sample-round-trip")
	if err != nil {
		t.Fatal(err)
	}
	if err := diagnostics.SetSelfReference(1e-9, 1e-9); err != nil {
		t.Fatal(err)
	}
	publishedHash, err := WeightsSHA256(ml.Initial(encoder))
	if err != nil {
		t.Fatal(err)
	}
	diagnostics.PublishedWeightsSHA256 = publishedHash
	path := filepath.Join(t.TempDir(), "nested", "candidate.json")
	summary, err := WriteDiagnostics(path, diagnostics)
	if err != nil {
		t.Fatal(err)
	}
	if len(summary.SHA256) != 64 || !summary.Equivalent || summary.CandidateMaxDifference != 0 {
		t.Fatalf("unexpected summary: %+v", summary)
	}
	loaded, err := ReadDiagnostics(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.SampleID != diagnostics.SampleID || loaded.RunID != diagnostics.RunID || len(loaded.ReferenceWeights) != diagnostics.Dimension {
		t.Fatal("diagnostics round trip changed identity or dimensions")
	}
	if _, err := WriteDiagnostics(path, diagnostics); err != nil {
		t.Fatalf("overwriting diagnostics failed: %v", err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"schema_version", "sample_id", "reference_weights", "candidate_weights", "candidate_max_difference", "absolute_tolerance", "relative_tolerance", "equivalent", "encoder_sha256", "selection"} {
		if _, ok := raw[key]; !ok {
			t.Fatalf("missing required diagnostics key %q", key)
		}
	}
	diagnostics.CandidateMaxDifference += 1
	if _, err := WriteDiagnostics(path, diagnostics); err == nil {
		t.Fatal("tampered maximum difference was accepted")
	}
}

func TestDiagnosticsRejectsInvalidSampleAndWeights(t *testing.T) {
	rows := syntheticRows()
	encoder, err := ml.Fit(rows)
	if err != nil {
		t.Fatal(err)
	}
	metrics := ml.Metrics{Examples: 20}
	candidate := candidateFixture(t, ml.Initial(encoder), metrics)
	for _, id := range []string{"", "has space", "slash/name", strings.Repeat("a", 129)} {
		if _, err := NewDiagnostics(candidate, id); err == nil {
			t.Fatalf("invalid sample id %q was accepted", id)
		}
	}
	candidate.Weights[0] = math.Inf(1)
	if _, err := NewDiagnostics(candidate, "sample-bad-weight"); err == nil {
		t.Fatal("non-finite candidate weight was accepted")
	}
}

func TestDistributedDiagnosticsRequireSequentialReference(t *testing.T) {
	encoder, err := ml.Fit(syntheticRows())
	if err != nil {
		t.Fatal(err)
	}
	c := candidateFixture(t, ml.Initial(encoder), ml.Metrics{Examples: 20})
	reference, err := NewDiagnostics(c, "reference-S")
	if err != nil {
		t.Fatal(err)
	}
	if err := reference.SetSelfReference(1e-9, 1e-9); err != nil {
		t.Fatal(err)
	}
	c.Mode = "distributed"
	c.RunID = "distributed-run"
	d, err := NewDiagnostics(c, "D1-r1")
	if err != nil {
		t.Fatal(err)
	}
	if err := d.SetSelfReference(1e-9, 1e-9); err == nil {
		t.Fatal("accepted distributed self-reference")
	}
	if err := d.SetReference(reference, 1e-9, 1e-9); err != nil {
		t.Fatal(err)
	}
	if err := d.Validate(); err != nil {
		t.Fatal(err)
	}
	reference.Mode = "distributed"
	if err := d.SetReference(reference, 1e-9, 1e-9); err == nil {
		t.Fatal("accepted distributed reference")
	}
	d.ReferenceMode = "distributed"
	if err := d.Validate(); err == nil {
		t.Fatal("accepted invalid reference mode on disk")
	}
}
