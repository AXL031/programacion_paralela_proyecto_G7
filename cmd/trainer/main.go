package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/ml"
	mongostore "github.com/proyecto-g7/transporte/internal/storage/mongo"
	"github.com/proyecto-g7/transporte/internal/training"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func env(k, f string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return f
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "trainer:", err)
		os.Exit(1)
	}
}
func run() error {
	path := flag.String("config", "configs/training.json", "training configuration")
	mode := flag.String("mode", "sequential", "sequential or distributed")
	flag.Parse()
	b, err := os.ReadFile(*path)
	if err != nil {
		return err
	}
	var c ml.Config
	if err := json.Unmarshal(b, &c); err != nil {
		return err
	}
	if err := c.Validate(); err != nil {
		return err
	}
	root, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(root, 20*time.Minute)
	defer cancel()
	var a training.Artifact
	var r training.Run
	switch *mode {
	case "sequential":
		repo, err := mongostore.New(ctx, env("MONGO_URI", "mongodb://mongo:27017"), env("MONGO_DATABASE", "transporte"))
		if err != nil {
			return err
		}
		defer repo.Close(context.Background())
		m, err := repo.Current(ctx)
		if err != nil {
			return err
		}
		if m == nil {
			return fmt.Errorf("no completed dataset")
		}
		a, r, err = training.Sequential(ctx, *m, c, repo)
		if err != nil {
			return err
		}
	case "distributed":
		a, r, err = distributed(ctx, c)
		if err != nil {
			return err
		}
	default:
		return fmt.Errorf("mode must be sequential or distributed")
	}
	e := json.NewEncoder(os.Stdout)
	e.SetIndent("", "  ")
	return e.Encode(map[string]any{"run": r, "artifact": a})
}
func distributed(ctx context.Context, c ml.Config) (training.Artifact, training.Run, error) {
	base := strings.TrimRight(env("MASTER_HTTP", "http://master:8081"), "/")
	client := &http.Client{Timeout: 10 * time.Second}
	var run training.Run
	var artifact training.Artifact
	call := func(method, path string, input, output any) error {
		var body []byte
		var err error
		if input != nil {
			body, err = json.Marshal(input)
			if err != nil {
				return err
			}
		}
		req, err := http.NewRequestWithContext(ctx, method, base+path, bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+os.Getenv("MASTER_API_TOKEN"))
		res, err := client.Do(req)
		if err != nil {
			return err
		}
		defer res.Body.Close()
		if res.StatusCode < 200 || res.StatusCode >= 300 {
			var v map[string]string
			json.NewDecoder(res.Body).Decode(&v)
			return fmt.Errorf("master HTTP %d: %s", res.StatusCode, v["error"])
		}
		return json.NewDecoder(res.Body).Decode(output)
	}
	if err := call("POST", "/runs", c, &run); err != nil {
		return artifact, run, err
	}
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return artifact, run, ctx.Err()
		case <-ticker.C:
			if err := call("GET", "/runs/"+run.ID, nil, &run); err != nil {
				return artifact, run, err
			}
			if run.Status == "failed" {
				return artifact, run, fmt.Errorf("run %s failed: %s", run.ID, run.Error)
			}
			if run.Status == "completed" {
				err := call("GET", "/models/"+run.ArtifactVersion, nil, &artifact)
				return artifact, run, err
			}
		}
	}
}
