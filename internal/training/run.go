package training

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/domain"
	"github.com/proyecto-g7/transporte/internal/ml"
	"time"
)

type Artifact struct {
	Version        string                   `json:"version"`
	DatasetID      string                   `json:"dataset_id"`
	SnapshotSHA256 string                   `json:"snapshot_sha256"`
	Encoder        ml.Encoder               `json:"encoder"`
	Weights        []float64                `json:"weights"`
	Config         ml.Config                `json:"config"`
	WindowMinutes  int                      `json:"window_minutes"`
	Timezone       string                   `json:"timezone"`
	TrainEnd       time.Time                `json:"train_end"`
	ValidationEnd  time.Time                `json:"validation_end"`
	CreatedAt      time.Time                `json:"created_at"`
	Evaluation     map[string]ml.Evaluation `json:"evaluation"`
	LossHistory    []float64                `json:"loss_history"`
	Selection      ml.Selection             `json:"selection"`
}

func (a Artifact) Validate() error {
	if len(a.Version) > 128 {
		return fmt.Errorf("artifact version too long")
	}
	for _, r := range a.Version {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_') {
			return fmt.Errorf("unsafe artifact version")
		}
	}
	if a.Version == "" || a.DatasetID == "" || len(a.SnapshotSHA256) != 64 || a.WindowMinutes < 1 || a.Timezone == "" {
		return fmt.Errorf("invalid artifact identity")
	}
	if err := a.Encoder.Validate(); err != nil {
		return err
	}
	if len(a.Weights) != a.Encoder.Dimension() {
		return fmt.Errorf("artifact weight dimension mismatch")
	}
	for _, w := range a.Weights {
		if !ml.Finite(w) {
			return fmt.Errorf("non-finite artifact weight")
		}
	}
	return a.Config.Validate()
}

type Run struct {
	ID                 string         `json:"run_id" bson:"_id"`
	Mode               string         `json:"mode"`
	Status             string         `json:"status"`
	DatasetID          string         `json:"dataset_id"`
	Config             ml.Config      `json:"config"`
	Progress           ml.Progress    `json:"progress"`
	StartedAt          time.Time      `json:"started_at"`
	CompletedAt        time.Time      `json:"completed_at,omitempty"`
	PreparationSeconds float64        `json:"preparation_seconds"`
	TrainingSeconds    float64        `json:"training_seconds"`
	EvaluationSeconds  float64        `json:"evaluation_seconds"`
	Workers            []string       `json:"workers"`
	Tasks              map[string]int `json:"tasks_by_worker"`
	ArtifactVersion    string         `json:"artifact_version,omitempty"`
	Error              string         `json:"error,omitempty"`
}
type Repo interface {
	SaveRun(context.Context, Run) error
	Publish(context.Context, Artifact) error
}
type Factory func(context.Context, domain.Manifest, ml.Encoder, ml.Dataset) (ml.Computer, []string, error)

func NewID() string {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return "run-" + hex.EncodeToString(b[:])
}

func Execute(ctx context.Context, m domain.Manifest, c ml.Config, runID, mode string, factory Factory, update func(Run)) (Artifact, Run, error) {
	r := Run{ID: runID, Mode: mode, Status: "preparing", DatasetID: m.ID, Config: c, StartedAt: time.Now().UTC(), Tasks: map[string]int{}}
	var a Artifact
	if err := c.Validate(); err != nil {
		return a, r, err
	}
	if m.Status != "complete" || m.Snapshot.Version != "raw-counts-v1" {
		return a, r, fmt.Errorf("completed raw-counts-v1 dataset required")
	}
	if update != nil {
		update(r)
	}
	started := time.Now()
	rows, err := ml.LoadSnapshot(ctx, m.Snapshot.Path, m.Snapshot.SHA256)
	if err != nil {
		return a, r, err
	}
	if int64(len(rows)) != m.Snapshot.Examples {
		return a, r, fmt.Errorf("snapshot row count mismatch")
	}
	for _, x := range rows {
		if x.TargetStart.Before(m.Start) || !x.TargetStart.Before(m.End) || x.Split == "train" && !x.TargetStart.Before(m.Snapshot.TrainEnd) || x.Split == "validation" && (x.TargetStart.Before(m.Snapshot.TrainEnd) || !x.TargetStart.Before(m.Snapshot.ValidationEnd)) || x.Split == "test" && x.TargetStart.Before(m.Snapshot.ValidationEnd) {
			return a, r, fmt.Errorf("feature split outside declared temporal bounds")
		}
	}
	encoder, err := ml.Fit(rows)
	if err != nil {
		return a, r, err
	}
	data, err := ml.Prepare(rows, encoder)
	if err != nil {
		return a, r, err
	}
	compute, workers, err := factory(ctx, m, encoder, data)
	if err != nil {
		return a, r, err
	}
	r.Workers = workers
	r.PreparationSeconds = time.Since(started).Seconds()
	r.Status = "running"
	if update != nil {
		update(r)
	}
	started = time.Now()
	weights, history, err := ml.Train(ctx, data.Train, encoder, c, compute, func(p ml.Progress) {
		r.Progress = p
		if update != nil {
			update(r)
		}
	})
	r.TrainingSeconds = time.Since(started).Seconds()
	if err != nil {
		return a, r, err
	}
	started = time.Now()
	weights, selection, err := ml.Select(data.Validation, encoder, weights)
	if err != nil {
		return a, r, err
	}
	eval := map[string]ml.Evaluation{}
	for name, split := range map[string][]ml.Row{"train": data.Train, "validation": data.Validation, "test": data.Test} {
		v, err := ml.Evaluate(split, weights)
		if err != nil {
			return a, r, err
		}
		eval[name] = v
	}
	r.EvaluationSeconds = time.Since(started).Seconds()
	a = Artifact{Version: runID, DatasetID: m.ID, SnapshotSHA256: m.Snapshot.SHA256, Encoder: encoder, Weights: weights, Config: c, WindowMinutes: m.WindowMinutes, Timezone: m.Timezone, TrainEnd: m.Snapshot.TrainEnd, ValidationEnd: m.Snapshot.ValidationEnd, CreatedAt: time.Now().UTC(), Evaluation: eval, LossHistory: history, Selection: selection}
	return a, r, a.Validate()
}
func Sequential(ctx context.Context, m domain.Manifest, c ml.Config, repo Repo) (Artifact, Run, error) {
	c.Workers = 1
	id := NewID()
	if err := repo.SaveRun(ctx, Run{ID: id, Mode: "sequential", Status: "preparing", Config: c, StartedAt: time.Now().UTC()}); err != nil {
		return Artifact{}, Run{}, err
	}
	a, r, err := Execute(ctx, m, c, id, "sequential", func(_ context.Context, _ domain.Manifest, _ ml.Encoder, d ml.Dataset) (ml.Computer, []string, error) {
		return func(ctx context.Context, _ int, w []float64, indices []int) (ml.Gradient, error) {
			return ml.Compute(ctx, d.Train, w, indices)
		}, nil, nil
	}, nil)
	if err == nil {
		err = repo.Publish(ctx, a)
	}
	r.CompletedAt = time.Now().UTC()
	r.Status = "completed"
	r.ArtifactVersion = a.Version
	if err != nil {
		r.Status = "failed"
		r.Error = err.Error()
		r.ArtifactVersion = ""
	}
	saveCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if e := repo.SaveRun(saveCtx, r); e != nil {
		if err != nil {
			err = fmt.Errorf("%w; persist run: %v", err, e)
		} else {
			err = e
		}
	}
	return a, r, err
}
