package master

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/cluster/protocol"
	"github.com/proyecto-g7/transporte/internal/cluster/worker"
	"github.com/proyecto-g7/transporte/internal/domain"
	"github.com/proyecto-g7/transporte/internal/features"
	"github.com/proyecto-g7/transporte/internal/ml"
	"github.com/proyecto-g7/transporte/internal/training"
	"math"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type fakeRepo struct {
	mu     sync.Mutex
	m      domain.Manifest
	models map[string]training.Artifact
	runs   map[string]training.Run
	active string
}

func (f *fakeRepo) Ping(context.Context) error                        { return nil }
func (f *fakeRepo) Current(context.Context) (*domain.Manifest, error) { m := f.m; return &m, nil }
func (f *fakeRepo) SaveRun(_ context.Context, r training.Run) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.runs[r.ID] = r
	return nil
}
func (f *fakeRepo) Publish(_ context.Context, a training.Artifact) error {
	if err := a.Validate(); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.models[a.Version] = a
	f.active = a.Version
	return nil
}
func (f *fakeRepo) Model(_ context.Context, id string) (training.Artifact, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if id == "current" {
		id = f.active
	}
	a, ok := f.models[id]
	if !ok {
		return a, fmt.Errorf("missing model")
	}
	return a, nil
}
func (f *fakeRepo) TrainingRun(_ context.Context, id string) (training.Run, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	r, ok := f.runs[id]
	if !ok {
		return r, fmt.Errorf("missing run")
	}
	return r, nil
}

func testSnapshot(t *testing.T) (domain.Manifest, string) {
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
			x := features.Example{ZoneID: zone, Origin: ts, TargetStart: ts, HourSin: math.Sin(2 * math.Pi * float64(ts.Hour()) / 24), HourCos: math.Cos(2 * math.Pi * float64(ts.Hour()) / 24), DayOfWeek: int(ts.Weekday()), Lag1: int64(10 + zone + i%9), Target: int64(11 + zone + i%9), Split: split}
			if err := encoder.Encode(x); err != nil {
				t.Fatal(err)
			}
		}
	}
	file.Close()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(b)
	m := domain.Manifest{ID: "synthetic-test", Status: "complete", Start: start, End: start.Add(160 * 15 * time.Minute), Timezone: "UTC", WindowMinutes: 15, Snapshot: domain.Snapshot{Version: "raw-counts-v1", Path: path, SHA256: hex.EncodeToString(hash[:]), Examples: 640, TrainEnd: start.Add(112 * 15 * time.Minute), ValidationEnd: start.Add(136 * 15 * time.Minute)}}
	return m, root
}
func eventually(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition timed out")
}
func startServer(t *testing.T) (*Server, *fakeRepo, string, string, context.Context) {
	t.Helper()
	m, root := testSnapshot(t)
	repo := &fakeRepo{m: m, models: map[string]training.Artifact{}, runs: map[string]training.Run{}}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := New(ctx, repo)
	done := make(chan struct{})
	go func() { s.Serve(listener); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	return s, repo, listener.Addr().String(), root, ctx
}
func startWorkers(t *testing.T, ctx context.Context, address, root string, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		child, stop := context.WithCancel(ctx)
		c := &worker.Client{ID: fmt.Sprintf("worker-%d", i), Address: address, DataRoot: root}
		done := make(chan struct{})
		go func() { c.Run(child); close(done) }()
		t.Cleanup(func() {
			stop()
			select {
			case <-done:
			case <-time.After(12 * time.Second):
				t.Error("worker did not shut down")
			}
		})
	}
}
func awaitRun(t *testing.T, s *Server, id string) training.Run {
	t.Helper()
	var r training.Run
	eventually(t, func() bool { r, _ = s.Run(id); return r.Status == "completed" || r.Status == "failed" })
	return r
}
func TestTCPTrainingEquivalentOneTwoFourAndArtifact(t *testing.T) {
	s, repo, address, root, ctx := startServer(t)
	startWorkers(t, ctx, address, root, 4)
	eventually(t, func() bool { return len(s.Workers()) == 4 })
	c := ml.Config{Epochs: 3, BatchSize: 65, LearningRate: 0.04, L2: 0.0001, Seed: 42, Workers: 1, TaskTimeoutSeconds: 2}
	reference, _, err := training.Sequential(ctx, repo.m, c, repo)
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []int{1, 2, 4} {
		c.Workers = n
		r, err := s.Start(c)
		if err != nil {
			t.Fatal(err)
		}
		done := awaitRun(t, s, r.ID)
		if done.Status != "completed" {
			t.Fatal(done.Error)
		}
		a, err := repo.Model(ctx, done.ArtifactVersion)
		if err != nil {
			t.Fatal(err)
		}
		for i, w := range a.Weights {
			if math.Abs(w-reference.Weights[i]) > 1e-11 {
				t.Fatalf("%d workers differ at weight %d", n, i)
			}
		}
		if len(done.Workers) != n || len(done.Tasks) != n {
			t.Fatal("wrong contributors")
		}
		for _, tasks := range done.Tasks {
			if tasks <= 0 {
				t.Fatal("worker did not contribute")
			}
		}
	}
}
func TestDuplicateGradientFailsWithoutReplacingModel(t *testing.T) {
	s, repo, address, root, ctx := startServer(t)
	startWorkers(t, ctx, address, root, 1)
	eventually(t, func() bool { return len(s.Workers()) == 1 })
	c := ml.Config{Epochs: 3, BatchSize: 65, LearningRate: 0.04, L2: 0.0001, Seed: 42, Workers: 2, TaskTimeoutSeconds: 2}
	prior, _, err := training.Sequential(ctx, repo.m, c, repo)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	stream := &protocol.Stream{Conn: conn}
	stream.Send(protocol.Message{Type: "register", WorkerID: "00-duplicate"})
	ack, err := stream.Receive(2 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			m, err := stream.Receive(5 * time.Second)
			if err != nil {
				return
			}
			switch m.Type {
			case "prepare":
				examples, err := ml.ReadSnapshot(ctx, m.Manifest.Snapshot.Path, m.Manifest.Snapshot.SHA256)
				if err != nil {
					return
				}
				data, err := ml.Prepare(examples, *m.Encoder)
				if err != nil {
					return
				}
				stream.Send(protocol.Message{Type: "ready", WorkerID: ack.WorkerID, Session: ack.Session, RunID: m.RunID, Count: len(data.Train)})
			case "task":
				examples, _ := ml.ReadSnapshot(ctx, repo.m.Snapshot.Path, repo.m.Snapshot.SHA256)
				encoder, _ := ml.Fit(examples)
				data, _ := ml.Prepare(examples, encoder)
				g, _ := ml.Compute(ctx, data.Train, m.Weights, m.Indices)
				reply := protocol.Message{Type: "gradient", WorkerID: ack.WorkerID, Session: ack.Session, RunID: m.RunID, Step: m.Step, TaskID: m.TaskID, Attempt: 1, ModelVersion: m.ModelVersion, Gradient: &g}
				stream.Send(reply)
				stream.Send(reply)
			}
		}
	}()
	eventually(t, func() bool { return len(s.Workers()) == 2 })
	r, err := s.Start(c)
	if err != nil {
		t.Fatal(err)
	}
	done := awaitRun(t, s, r.ID)
	if done.Status != "failed" {
		t.Fatal("duplicate gradient accepted")
	}
	active, err := repo.Model(ctx, "current")
	if err != nil || active.Version != prior.Version {
		t.Fatal("failed run replaced published model")
	}
}

func TestSilentWorkerTimesOutWithoutPublishing(t *testing.T) {
	s, repo, address, root, ctx := startServer(t)
	startWorkers(t, ctx, address, root, 1)
	eventually(t, func() bool { return len(s.Workers()) == 1 })
	c := ml.Config{Epochs: 2, BatchSize: 65, LearningRate: 0.04, L2: 0.0001, Seed: 42, Workers: 2, TaskTimeoutSeconds: 1}
	prior, _, err := training.Sequential(ctx, repo.m, c, repo)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	stream := &protocol.Stream{Conn: conn}
	stream.Send(protocol.Message{Type: "register", WorkerID: "00-silent"})
	ack, err := stream.Receive(2 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			m, err := stream.Receive(5 * time.Second)
			if err != nil {
				return
			}
			if m.Type == "prepare" {
				stream.Send(protocol.Message{Type: "ready", WorkerID: ack.WorkerID, Session: ack.Session, RunID: m.RunID, Count: 448})
			}
		}
	}()
	eventually(t, func() bool { return len(s.Workers()) == 2 })
	r, err := s.Start(c)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Start(c); err == nil {
		t.Fatal("concurrent training accepted")
	}
	done := awaitRun(t, s, r.ID)
	if done.Status != "failed" {
		t.Fatal("silent worker did not fail run")
	}
	a, err := repo.Model(ctx, "current")
	if err != nil || a.Version != prior.Version {
		t.Fatal("timeout replaced published model")
	}
}
