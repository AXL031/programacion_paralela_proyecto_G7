package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestBoundAndValidation(t *testing.T) {
	var active, maximum atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := active.Add(1)
		defer active.Add(-1)
		for old := maximum.Load(); n > old; old = maximum.Load() {
			if maximum.CompareAndSwap(old, n) {
				break
			}
		}
		time.Sleep(3 * time.Millisecond)
		var q query
		json.NewDecoder(r.Body).Decode(&q)
		v := 1.0
		i := int64(1)
		hit := true
		json.NewEncoder(w).Encode(prediction{Dataset: q.Dataset, Zone: q.Zone, Origin: q.Origin, Horizon: q.Horizon, Version: "v1", Predicted: &v, Previous: &i, Actual: &i, Hit: &hit, Latency: &v})
	}))
	defer server.Close()
	queries := make([]query, 20)
	for i := range queries {
		queries[i] = query{"ds", 1, time.Unix(0, 0), 15}
	}
	samples, elapsed := batch(context.Background(), server.Client(), server.URL, "token", queries, "v1", "warm", 3, time.Second)
	if maximum.Load() > 3 || maximum.Load() < 2 {
		t.Fatalf("unexpected concurrency %d", maximum.Load())
	}
	report := summarize(samples, elapsed, "warm", 3, "v1", "ds")
	if report.Errors != 0 || report.CacheHits != 20 || report.Attempted != 20 {
		t.Fatalf("invalid report %+v", report)
	}
	a := one(context.Background(), server.Client(), server.URL, "token", queries[0], "v1", "cold", 0, time.Second)
	if a.Success || a.Error != "unexpected_cache_state" {
		t.Fatal("cold case accepted a hit")
	}
	a = one(context.Background(), server.Client(), server.URL, "token", queries[0], "other", "warm", 0, time.Second)
	if a.Success {
		t.Fatal("accepted wrong model")
	}
}
func TestErrorsTimeoutsAndPercentiles(t *testing.T) {
	for _, kind := range []string{"json", "http", "timeout", "missing"} {
		t.Run(kind, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch kind {
				case "http":
					w.WriteHeader(503)
				case "timeout":
					time.Sleep(40 * time.Millisecond)
				case "json":
					w.Write([]byte("invalid"))
				case "missing":
					w.Write([]byte(`{"dataset_id":"ds"}`))
				}
			}))
			defer server.Close()
			a := one(context.Background(), server.Client(), server.URL, "token", query{"ds", 1, time.Unix(0, 0), 15}, "v1", "cold", 0, 10*time.Millisecond)
			if a.Success || a.Error == "" {
				t.Fatal("error hidden")
			}
			if kind == "timeout" && !a.Timeout {
				t.Fatal("timeout not retained")
			}
		})
	}
	r := summarize([]attempt{{Milliseconds: 1, Success: true}, {Milliseconds: 2, Success: true}, {Milliseconds: 3, Success: true}, {Milliseconds: 200, Error: "bad"}}, time.Second, "cold", 1, "v1", "ds")
	if r.P50 != 2 || r.P95 != 200 || r.Errors != 1 || r.Under100 != .75 || r.Objective || r.Throughput != 4 || r.GoodThroughput != 3 {
		t.Fatalf("bad aggregates %+v", r)
	}
}

func TestPrewarmVerifiesCacheAfterFallbackWrites(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var q query
		json.NewDecoder(r.Body).Decode(&q)
		hit := calls.Add(1) >= 3
		v := 1.0
		i := int64(1)
		json.NewEncoder(w).Encode(prediction{Dataset: q.Dataset, Zone: q.Zone, Origin: q.Origin, Horizon: q.Horizon, Version: "v1", Predicted: &v, Previous: &i, Actual: &i, Hit: &hit, Latency: &v})
	}))
	defer server.Close()
	if err := prewarm(context.Background(), server.Client(), server.URL, "token", []query{{"ds", 1, time.Unix(0, 0), 15}}, "v1", 1); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 3 {
		t.Fatalf("prewarm stopped without verified hit: %d", calls.Load())
	}
}
