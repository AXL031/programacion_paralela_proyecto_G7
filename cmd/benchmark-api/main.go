// benchmark-api measures authenticated prediction requests with a bounded,
// closed-loop client. Credentials are read from the environment, never flags.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/proyecto-g7/transporte/internal/domain"
)

type query struct {
	Dataset string    `json:"dataset_id"`
	Zone    int       `json:"zone_id"`
	Origin  time.Time `json:"forecast_origin"`
	Horizon int       `json:"horizon_minutes"`
}
type prediction struct {
	Dataset   string    `json:"dataset_id"`
	Zone      int       `json:"zone_id"`
	Origin    time.Time `json:"forecast_origin"`
	Horizon   int       `json:"horizon_minutes"`
	Version   string    `json:"model_version"`
	Predicted *float64  `json:"predicted_observed_trips"`
	Previous  *int64    `json:"previous_observed_trips"`
	Actual    *int64    `json:"actual_observed_trips"`
	Hit       *bool     `json:"cache_hit"`
	Latency   *float64  `json:"latency_ms"`
}
type attempt struct {
	Index        int       `json:"index"`
	Started      time.Time `json:"started_at"`
	Milliseconds float64   `json:"latency_ms"`
	Status       int       `json:"http_status"`
	Success      bool      `json:"success"`
	CacheHit     bool      `json:"cache_hit"`
	Timeout      bool      `json:"timeout"`
	Error        string    `json:"error,omitempty"`
}
type report struct {
	Scenario       string         `json:"scenario"`
	Concurrency    int            `json:"concurrency"`
	Model          string         `json:"model_version"`
	Dataset        string         `json:"dataset_id"`
	Attempted      int            `json:"attempted"`
	Completed      int            `json:"completed"`
	Succeeded      int            `json:"succeeded"`
	Errors         int            `json:"errors"`
	Timeouts       int            `json:"timeouts"`
	CacheHits      int            `json:"cache_hits"`
	P50            float64        `json:"p50_ms"`
	P95            float64        `json:"p95_ms"`
	P99            float64        `json:"p99_ms"`
	Max            float64        `json:"max_ms"`
	Seconds        float64        `json:"elapsed_seconds"`
	Throughput     float64        `json:"throughput_total"`
	GoodThroughput float64        `json:"throughput_success"`
	Under100       float64        `json:"proportion_under_100_ms"`
	Objective      bool           `json:"objective_met"`
	ErrorCounts    map[string]int `json:"error_counts"`
	ErrorLatencies []float64      `json:"error_latencies_ms"`
	Samples        []attempt      `json:"samples"`
	LoadModel      string         `json:"load_model"`
}

func one(ctx context.Context, client *http.Client, base, token string, q query, version, expected string, index int, timeout time.Duration) attempt {
	a := attempt{Index: index, Started: time.Now().UTC()}
	b, _ := json.Marshal(q)
	c, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(c, http.MethodPost, base+"/api/v1/predictions", bytes.NewReader(b))
	if err != nil {
		a.Error = "invalid_request"
		return a
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	start := time.Now()
	res, err := client.Do(req)
	var body []byte
	if err == nil {
		a.Status = res.StatusCode
		body, err = io.ReadAll(io.LimitReader(res.Body, 65537))
		res.Body.Close()
	}
	a.Milliseconds = float64(time.Since(start)) / float64(time.Millisecond)
	if err != nil {
		a.Timeout = c.Err() == context.DeadlineExceeded
		a.Error = "transport_or_body_error"
		return a
	}
	if a.Status != 200 {
		a.Error = "unexpected_http_status"
		return a
	}
	var p prediction
	if len(body) > 65536 || json.Unmarshal(body, &p) != nil {
		a.Error = "invalid_json"
		return a
	}
	if p.Dataset != q.Dataset || p.Version != version || p.Zone != q.Zone || !p.Origin.Equal(q.Origin) || p.Horizon != q.Horizon || p.Hit == nil || p.Predicted == nil || p.Previous == nil || p.Actual == nil || p.Latency == nil || math.IsNaN(*p.Predicted) || math.IsInf(*p.Predicted, 0) || *p.Predicted < 0 || *p.Previous < 0 || *p.Actual < 0 || *p.Latency < 0 {
		a.Error = "invalid_prediction_identity_or_values"
		return a
	}
	a.CacheHit = *p.Hit
	if (expected == "warm" && !a.CacheHit) || (expected != "any" && expected != "warm" && a.CacheHit) {
		a.Error = "unexpected_cache_state"
		return a
	}
	a.Success = true
	return a
}
func batch(ctx context.Context, client *http.Client, base, token string, queries []query, version, expected string, concurrency int, timeout time.Duration) ([]attempt, time.Duration) {
	out := make([]attempt, len(queries))
	jobs := make(chan int, len(queries))
	for i := range queries {
		jobs <- i
	}
	close(jobs)
	var wg sync.WaitGroup
	start := time.Now()
	for w := 0; w < concurrency; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				out[i] = one(ctx, client, base, token, queries[i], version, expected, i, timeout)
			}
		}()
	}
	wg.Wait()
	return out, time.Since(start)
}
func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	i := int(math.Ceil(p*float64(len(sorted)))) - 1
	if i < 0 {
		i = 0
	}
	return sorted[i]
}
func summarize(samples []attempt, elapsed time.Duration, scenario string, concurrency int, version, dataset string) report {
	r := report{Scenario: scenario, Concurrency: concurrency, Model: version, Dataset: dataset, Attempted: len(samples), Completed: len(samples), Seconds: elapsed.Seconds(), Samples: samples, ErrorCounts: map[string]int{}, ErrorLatencies: []float64{}, LoadModel: "closed loop, bounded workers, persistent connections; login/smoke/prewarm excluded"}
	latencies := make([]float64, len(samples))
	under := 0
	for i, a := range samples {
		latencies[i] = a.Milliseconds
		if a.Success {
			r.Succeeded++
			if a.CacheHit {
				r.CacheHits++
			}
			if a.Milliseconds < 100 {
				under++
			}
		} else {
			r.Errors++
			r.ErrorCounts[a.Error]++
			r.ErrorLatencies = append(r.ErrorLatencies, a.Milliseconds)
		}
		if a.Timeout {
			r.Timeouts++
		}
	}
	sort.Float64s(latencies)
	r.P50 = percentile(latencies, .5)
	r.P95 = percentile(latencies, .95)
	r.P99 = percentile(latencies, .99)
	r.Max = percentile(latencies, 1)
	if r.Seconds > 0 {
		r.Throughput = float64(r.Completed) / r.Seconds
		r.GoodThroughput = float64(r.Succeeded) / r.Seconds
	}
	if len(samples) > 0 {
		r.Under100 = float64(under) / float64(len(samples))
	}
	r.Objective = r.Errors == 0 && r.P95 < 100
	return r
}
func jsonCall(client *http.Client, method, url, token string, input, output any) error {
	var body []byte
	var err error
	if input != nil {
		body, err = json.Marshal(input)
		if err != nil {
			return err
		}
	}
	req, err := http.NewRequest(method, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("HTTP transport failed")
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return fmt.Errorf("HTTP status %d", res.StatusCode)
	}
	if output == nil {
		_, err = io.Copy(io.Discard, res.Body)
		return err
	}
	return json.NewDecoder(io.LimitReader(res.Body, 1048576)).Decode(output)
}
func run() error {
	base := flag.String("base-url", "http://api:8080", "isolated API URL")
	scenario := flag.String("cache", "cold", "cold/warm/unavailable")
	n := flag.Int("requests", 1000, "measured requests")
	concurrency := flag.Int("concurrency", 1, "in-flight bound")
	output := flag.String("output", "", "raw report path")
	user := flag.String("user", "benchmark", "login username (no password on command line)")
	flag.Parse()
	if *n < 1 || *n > 100000 || *concurrency < 1 || *concurrency > 64 || (*scenario != "cold" && *scenario != "warm" && *scenario != "unavailable") || *output == "" {
		return fmt.Errorf("invalid workload flags")
	}
	transport := &http.Transport{MaxConnsPerHost: *concurrency, MaxIdleConnsPerHost: *concurrency, MaxIdleConns: *concurrency}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	var login struct {
		Token string `json:"access_token"`
	}
	if err := jsonCall(client, "POST", *base+"/api/v1/auth/login", "", map[string]string{"username": *user, "password": os.Getenv("BENCH_PASSWORD")}, &login); err != nil {
		return fmt.Errorf("benchmark login: %w", err)
	}
	if login.Token == "" {
		return fmt.Errorf("missing session token")
	}
	defer jsonCall(client, "POST", *base+"/api/v1/auth/logout", login.Token, map[string]any{}, nil)
	var dataset domain.Manifest
	if err := jsonCall(client, "GET", *base+"/api/v1/datasets/current", login.Token, nil, &dataset); err != nil {
		return err
	}
	var model struct {
		Ready   bool   `json:"ready"`
		Version string `json:"version"`
		Dataset string `json:"dataset_id"`
	}
	deadline := time.Now().Add(time.Minute)
	for {
		err := jsonCall(client, "GET", *base+"/api/v1/models/current", login.Token, nil, &model)
		if err == nil && model.Ready && model.Dataset == dataset.ID {
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("model not ready for dataset")
		}
		time.Sleep(time.Second)
	}
	if dataset.WindowMinutes < 1 || len(dataset.Zones) == 0 {
		return fmt.Errorf("invalid dataset inventory")
	}
	step := time.Duration(dataset.WindowMinutes) * time.Minute
	makeQuery := func(i int) query {
		return query{dataset.ID, dataset.Zones[i%len(dataset.Zones)].ID, dataset.Start.Add(time.Duration(i/len(dataset.Zones)+1) * step), dataset.WindowMinutes}
	}
	if !makeQuery(*n).Origin.Add(step).Before(dataset.End.Add(time.Nanosecond)) {
		return fmt.Errorf("insufficient unique historical keys")
	}
	queries := make([]query, *n)
	for i := range queries {
		queries[i] = makeQuery(i)
	}
	smoke := one(context.Background(), client, *base, login.Token, makeQuery(*n), model.Version, "any", -1, 15*time.Second)
	if !smoke.Success {
		return fmt.Errorf("prediction smoke: %s", smoke.Error)
	}
	if *scenario == "warm" {
		warm, _ := batch(context.Background(), client, *base, login.Token, queries, model.Version, "any", *concurrency, 15*time.Second)
		for _, a := range warm {
			if !a.Success {
				return fmt.Errorf("prewarm failed: %s", a.Error)
			}
		}
	}
	samples, elapsed := batch(context.Background(), client, *base, login.Token, queries, model.Version, *scenario, *concurrency, 15*time.Second)
	r := summarize(samples, elapsed, *scenario, *concurrency, model.Version, dataset.ID)
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	if err = os.WriteFile(*output, append(b, '\n'), 0644); err != nil {
		return err
	}
	if r.Errors != 0 {
		return fmt.Errorf("%d unexpected request errors; see raw report", r.Errors)
	}
	return nil
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "benchmark-api:", err)
		os.Exit(1)
	}
}
