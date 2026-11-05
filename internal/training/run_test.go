package training

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/proyecto-g7/transporte/internal/domain"
	"github.com/proyecto-g7/transporte/internal/features"
	"github.com/proyecto-g7/transporte/internal/ml"
)

type testRepo struct {
	mu           sync.Mutex
	current      *Artifact
	runs         map[string]Run
	published    []Artifact
	publishErr   error
	publishDelay time.Duration
}

func newTestRepo() *testRepo {
	return &testRepo{runs: map[string]Run{}}
}

func (r *testRepo) SaveRun(_ context.Context, run Run) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.runs[run.ID] = run
	return nil
}

func (r *testRepo) Publish(_ context.Context, artifact Artifact) error {
	if err := artifact.Validate(); err != nil {
		return err
	}
	r.mu.Lock()
	delay := r.publishDelay
	publishErr := r.publishErr
	r.mu.Unlock()
	if delay > 0 {
		time.Sleep(delay)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if publishErr != nil {
		return publishErr
	}
	r.published = append(r.published, artifact)
	copy := artifact
	r.current = &copy
	return nil
}

func (r *testRepo) currentArtifact() *Artifact {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.current
}

func (r *testRepo) setPublishError(err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.publishErr = err
}

func testManifest(t *testing.T, tweak func(*domain.Manifest)) (domain.Manifest, string) {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "features.ndjson")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	encoder := json.NewEncoder(file)
	start := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 160; i++ {
		split := "train"
		if i >= 136 {
			split = "test"
		} else if i >= 112 {
			split = "validation"
		}
		ts := start.Add(time.Duration(i) * 15 * time.Minute)
		for zone := 1; zone <= 4; zone++ {
			x := features.Example{
				ZoneID:      zone,
				Origin:      ts,
				TargetStart: ts,
				HourSin:     math.Sin(2 * math.Pi * float64(ts.Hour()) / 24),
				HourCos:     math.Cos(2 * math.Pi * float64(ts.Hour()) / 24),
				DayOfWeek:   int(ts.Weekday()),
				Lag1:        int64(10 + zone + i%9),
				Target:      int64(11 + zone + i%9),
				Split:       split,
			}
			if err := encoder.Encode(x); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(b)
	m := domain.Manifest{
		ID:            "synthetic-training-test",
		Status:        "complete",
		Start:         start,
		End:           start.Add(160 * 15 * time.Minute),
		Timezone:      "UTC",
		WindowMinutes: 15,
		Snapshot: domain.Snapshot{
			Version:       "raw-counts-v1",
			Path:          path,
			SHA256:        hex.EncodeToString(hash[:]),
			Examples:      640,
			TrainEnd:      start.Add(112 * 15 * time.Minute),
			ValidationEnd: start.Add(136 * 15 * time.Minute),
		},
	}
	if tweak != nil {
		tweak(&m)
	}
	return m, root
}

func testConfig() ml.Config {
	return ml.Config{Epochs: 3, BatchSize: 65, LearningRate: 0.04, L2: 0.0001, Seed: 42, Workers: 1, TaskTimeoutSeconds: 2}
}

func TestSequentialCapturesCandidateAndPhases(t *testing.T) {
	manifest, _ := testManifest(t, nil)
	repo := newTestRepo()
	repo.publishDelay = 2 * time.Millisecond
	artifact, run, candidate, err := SequentialWithDiagnostics(context.Background(), manifest, testConfig(), repo)
	if err != nil {
		t.Fatal(err)
	}
	if run.Status != "completed" || run.ArtifactVersion != artifact.Version {
		t.Fatalf("unexpected run state: %+v", run)
	}
	if candidate.RunID != run.ID || candidate.Mode != "sequential" {
		t.Fatal("candidate identity does not match run")
	}
	if candidate.TrainExamples != 448 || candidate.ValidationExamples != 96 || candidate.TestExamples != 96 {
		t.Fatalf("unexpected split counts: %+v", candidate)
	}
	if candidate.Dimension != candidate.Encoder.Dimension() || len(candidate.Weights) != candidate.Dimension {
		t.Fatal("candidate dimensions are inconsistent")
	}
	if candidate.Selection.Method == "" || candidate.Selection.CandidateValidation != candidate.Validation {
		t.Fatal("candidate validation metrics were not captured before selection")
	}
	if run.PreparationSeconds <= 0 || run.TrainingSeconds < 0 || run.EvaluationSeconds < 0 || run.PublicationSeconds <= 0 || run.TotalSeconds <= 0 {
		t.Fatalf("phases were not instrumented: %+v", run)
	}
	phaseSum := run.PreparationSeconds + run.TrainingSeconds + run.EvaluationSeconds + run.PublicationSeconds
	if run.TotalSeconds+1e-9 < phaseSum {
		t.Fatalf("total %.9f is smaller than phase sum %.9f", run.TotalSeconds, phaseSum)
	}
	if len(repo.published) != 1 {
		t.Fatal("successful sequential run did not publish exactly once")
	}
	if candidate.Selection.Method == "persistence" {
		differs := false
		for i := range candidate.Weights {
			if candidate.Weights[i] != artifact.Weights[i] {
				differs = true
				break
			}
		}
		if !differs {
			t.Fatal("candidate and selected persistence weights are indistinguishable")
		}
	}
}

func TestExecuteTimesComputePhase(t *testing.T) {
	manifest, _ := testManifest(t, nil)
	config := testConfig()
	config.Epochs = 1
	config.BatchSize = 448
	factory := func(_ context.Context, _ domain.Manifest, _ ml.Encoder, data ml.Dataset) (ml.Computer, []string, error) {
		return func(ctx context.Context, _ int, weights []float64, indices []int) (ml.Gradient, error) {
			time.Sleep(2 * time.Millisecond)
			return ml.Compute(ctx, data.Train, weights, indices)
		}, nil, nil
	}
	_, run, candidate, err := Execute(context.Background(), manifest, config, "run-timing", "sequential", factory, nil)
	if err != nil {
		t.Fatal(err)
	}
	if run.PreparationSeconds <= 0 || run.TrainingSeconds <= 0 {
		t.Fatalf("preparation/compute phases were not timed: %+v", run)
	}
	if len(candidate.Weights) != candidate.Dimension {
		t.Fatal("candidate was not captured")
	}
}

func TestPublicationFailureKeepsPreviousModel(t *testing.T) {
	manifest, _ := testManifest(t, nil)
	repo := newTestRepo()
	repo.publishDelay = 2 * time.Millisecond
	config := testConfig()
	first, _, _, err := SequentialWithDiagnostics(context.Background(), manifest, config, repo)
	if err != nil {
		t.Fatal(err)
	}
	repo.setPublishError(fmt.Errorf("deliberate publication failure"))
	_, failedRun, candidate, err := SequentialWithDiagnostics(context.Background(), manifest, config, repo)
	if err == nil {
		t.Fatal("publication failure was not reported")
	}
	if failedRun.Status != "failed" || failedRun.ArtifactVersion != "" {
		t.Fatalf("failure was not recorded: %+v", failedRun)
	}
	if failedRun.PublicationSeconds <= 0 || failedRun.TotalSeconds <= 0 {
		t.Fatal("publication attempt was not timed")
	}
	if len(candidate.Weights) == 0 {
		t.Fatal("candidate should still be available for diagnostics")
	}
	current := repo.currentArtifact()
	if current == nil || current.Version != first.Version {
		t.Fatal("failed publication replaced the previous model")
	}
}

func TestTemporalLeakRejected(t *testing.T) {
	manifest, _ := testManifest(t, func(m *domain.Manifest) {
		m.Snapshot.TrainEnd = m.Start.Add(100 * 15 * time.Minute)
	})
	repo := newTestRepo()
	_, run, candidate, err := SequentialWithDiagnostics(context.Background(), manifest, testConfig(), repo)
	if err == nil || !strings.Contains(err.Error(), "temporal") {
		t.Fatalf("temporal leak was not rejected: %v", err)
	}
	if run.Status != "failed" || run.Error == "" {
		t.Fatalf("failed run was not recorded: %+v", run)
	}
	if len(candidate.Weights) != 0 {
		t.Fatal("candidate should not exist when split validation fails")
	}
	if repo.currentArtifact() != nil {
		t.Fatal("invalid split published a model")
	}
}
