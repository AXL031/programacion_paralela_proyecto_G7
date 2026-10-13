package api

import (
	"context"
	"errors"
	"github.com/proyecto-g7/transporte/internal/domain"
	"github.com/proyecto-g7/transporte/internal/features"
	"github.com/proyecto-g7/transporte/internal/ml"
	"github.com/proyecto-g7/transporte/internal/training"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type modelStore struct {
	mu      sync.Mutex
	m       domain.Manifest
	a       training.Artifact
	windows []domain.Window
	fail    bool
}

func (s *modelStore) Ping(context.Context) error { return nil }
func (s *modelStore) Current(context.Context) (*domain.Manifest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.m
	return &m, nil
}
func (s *modelStore) Observations(context.Context, string, int, time.Time, time.Time) ([]domain.Window, error) {
	return nil, nil
}
func (s *modelStore) Windows(context.Context, string) ([]domain.Window, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.windows, nil
}
func (s *modelStore) Model(context.Context, string) (training.Artifact, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fail {
		return training.Artifact{}, errors.New("offline")
	}
	return s.a, nil
}

type memoryCache struct {
	mu     sync.Mutex
	values map[string]string
	fail   bool
}

func (c *memoryCache) Get(_ context.Context, key string) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.fail {
		return "", errors.New("cache offline")
	}
	v, ok := c.values[key]
	if !ok {
		return "", nil
	}
	return v, nil
}
func (c *memoryCache) Set(_ context.Context, key, value string, _ time.Duration) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.fail {
		return errors.New("cache offline")
	}
	c.values[key] = value
	return nil
}
func predictionFixture(t *testing.T) (*Runtime, *modelStore, *memoryCache, PredictionRequest) {
	t.Helper()
	start := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	e, err := ml.Fit([]features.Example{{ZoneID: 161, Lag1: 5, Target: 6, Split: "train"}, {ZoneID: 161, Lag1: 7, Target: 9, Split: "train"}})
	if err != nil {
		t.Fatal(err)
	}
	m := domain.Manifest{ID: "ds-test", LoadID: "load-test", Start: start, End: start.Add(90 * time.Minute), WindowMinutes: 15, Timezone: "UTC", Snapshot: domain.Snapshot{SHA256: strings.Repeat("a", 64), Windows: 6}}
	a := training.Artifact{Version: "run-test", DatasetID: m.ID, SnapshotSHA256: m.Snapshot.SHA256, Encoder: e, Weights: ml.Initial(e), WindowMinutes: 15, Timezone: "UTC", Config: ml.Config{Epochs: 1, BatchSize: 4, LearningRate: 0.04, Workers: 1, TaskTimeoutSeconds: 1}, Selection: ml.Selection{Method: "persistence"}}
	s := &modelStore{m: m, a: a}
	for i, count := range []int64{5, 7, 50, 3, 0, 0} {
		s.windows = append(s.windows, domain.Window{LoadID: m.LoadID, ZoneID: 161, Start: start.Add(time.Duration(i) * 15 * time.Minute), Count: count})
	}
	cache := &memoryCache{values: map[string]string{}}
	r := NewRuntime(s, cache)
	if err := r.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	return r, s, cache, PredictionRequest{DatasetID: m.ID, ZoneID: 161, Origin: start.Add(30 * time.Minute), Horizon: 15}
}
func TestPredictionUsesPastAndCacheIsVersioned(t *testing.T) {
	r, s, cache, input := predictionFixture(t)
	a, err := r.Predict(context.Background(), input)
	if err != nil || math.Abs(a.Predicted-7) > 1e-10 || a.Actual != 50 || a.CacheHit {
		t.Fatalf("prediction used target or failed: %+v %v", a, err)
	}
	b, err := r.Predict(context.Background(), input)
	if err != nil || !b.CacheHit {
		t.Fatal("cache not reused")
	}
	s.mu.Lock()
	s.a.Version = "run-next"
	s.a.Weights = append([]float64(nil), s.a.Weights...)
	s.a.Weights[s.a.Encoder.BiasIndex()] += 1
	s.mu.Unlock()
	if err := r.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	c, err := r.Predict(context.Background(), input)
	if err != nil || c.CacheHit || c.Version == b.Version || c.Predicted == b.Predicted {
		t.Fatal("old cached model reused")
	}
	cache.mu.Lock()
	cache.fail = true
	cache.mu.Unlock()
	if _, err := r.Predict(context.Background(), input); err != nil {
		t.Fatal("cache failure blocked prediction")
	}
}
func TestBadInputAndRefreshRetainsPreviousModel(t *testing.T) {
	r, s, _, input := predictionFixture(t)
	bad := input
	bad.Origin = bad.Origin.Add(time.Minute)
	if _, err := r.Predict(context.Background(), bad); err == nil {
		t.Fatal("unaligned origin accepted")
	}
	bad = input
	bad.DatasetID = "other"
	if _, err := r.Predict(context.Background(), bad); err == nil {
		t.Fatal("dataset mismatch accepted")
	}
	bad = input
	bad.Origin = s.m.Start
	if _, err := r.Predict(context.Background(), bad); err == nil {
		t.Fatal("missing history accepted")
	}
	s.mu.Lock()
	s.fail = true
	s.mu.Unlock()
	if err := r.Refresh(context.Background()); err == nil {
		t.Fatal("bad refresh succeeded")
	}
	if _, err := r.Predict(context.Background(), input); err != nil {
		t.Fatal("failed refresh removed good model")
	}
}
func TestStrictPredictionRequestAndRedisOptional(t *testing.T) {
	r, s, _, _ := predictionFixture(t)
	h := New(s, func(context.Context) error { return errors.New("offline") }, Options{Runtime: r})
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/health/ready", nil))
	if w.Code != http.StatusOK {
		t.Fatal("optional cache made API unavailable")
	}
	w = httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("POST", "/api/v1/predictions", strings.NewReader(`{} {}`)))
	if w.Code != 400 {
		t.Fatal("multiple JSON objects accepted")
	}
}
func TestConcurrentPredictionsDuringModelSwap(t *testing.T) {
	r, s, _, input := predictionFixture(t)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 20; j++ {
				if _, err := r.Predict(context.Background(), input); err != nil {
					t.Error(err)
				}
			}
		}()
	}
	for i := 0; i < 10; i++ {
		s.mu.Lock()
		s.a.Version = "run-swap" + strings.Repeat("x", i)
		s.mu.Unlock()
		if err := r.Refresh(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	wg.Wait()
}
