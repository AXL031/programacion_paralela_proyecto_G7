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
	diagnosticsPath := flag.String("diagnostics", "", "optional candidate diagnostics JSON output")
	sampleID := flag.String("sample-id", "", "benchmark sample identifier for diagnostics")
	referencePath := flag.String("reference-diagnostics", "", "sequential reference diagnostics for a distributed candidate")
	toleranceAbsolute := flag.Float64("tolerance-abs", 1e-9, "absolute per-parameter candidate tolerance")
	toleranceRelative := flag.Float64("tolerance-rel", 1e-9, "relative per-parameter candidate tolerance")
	flag.Parse()
	if *diagnosticsPath != "" {
		if err := training.ValidateSampleID(*sampleID); err != nil {
			return fmt.Errorf("invalid -sample-id: %w", err)
		}
	} else if *sampleID != "" || *referencePath != "" {
		return fmt.Errorf("-sample-id and -reference-diagnostics require -diagnostics")
	}
	if *referencePath != "" && *mode != "distributed" {
		return fmt.Errorf("-reference-diagnostics is only valid with distributed mode")
	}
	if *mode == "distributed" && *diagnosticsPath != "" && *referencePath == "" {
		return fmt.Errorf("distributed diagnostics require a sequential -reference-diagnostics")
	}
	if !ml.Finite(*toleranceAbsolute) || !ml.Finite(*toleranceRelative) || *toleranceAbsolute < 0 || *toleranceRelative < 0 {
		return fmt.Errorf("tolerances must be finite and non-negative")
	}
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
	var candidate training.Candidate
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
		a, r, candidate, err = training.SequentialWithDiagnostics(ctx, *m, c, repo)
		if err != nil {
			return err
		}
	case "distributed":
		a, r, candidate, err = distributed(ctx, c, *diagnosticsPath != "")
		if err != nil {
			return err
		}
	default:
		return fmt.Errorf("mode must be sequential or distributed")
	}
	var summary *training.DiagnosticsSummary
	var diagnosticsErr error
	if *diagnosticsPath != "" {
		s, err := buildAndWriteDiagnostics(*diagnosticsPath, *sampleID, candidate, a, *referencePath, *toleranceAbsolute, *toleranceRelative)
		summary, diagnosticsErr = &s, err
	}
	e := json.NewEncoder(os.Stdout)
	e.SetIndent("", "  ")
	out := map[string]any{"run": r, "artifact": a}
	if summary != nil {
		out["diagnostics"] = *summary
	}
	if err := e.Encode(out); err != nil {
		return err
	}
	return diagnosticsErr
}

// buildAndWriteDiagnostics keeps benchmark evidence separate from the
// published model. A numeric divergence is written and then returned as an
// error so the adapter cannot present the sample as successful.
func buildAndWriteDiagnostics(path, sampleID string, candidate training.Candidate, artifact training.Artifact, referencePath string, absolute, relative float64) (training.DiagnosticsSummary, error) {
	d, err := training.NewDiagnostics(candidate, sampleID)
	if err != nil {
		return training.DiagnosticsSummary{}, err
	}
	if referencePath != "" {
		reference, err := training.ReadDiagnostics(referencePath)
		if err != nil {
			return training.DiagnosticsSummary{}, fmt.Errorf("read reference diagnostics: %w", err)
		}
		if err := d.SetReference(reference, absolute, relative); err != nil {
			return training.DiagnosticsSummary{}, err
		}
	} else if err := d.SetSelfReference(absolute, relative); err != nil {
		return training.DiagnosticsSummary{}, err
	}
	publishedHash, err := training.WeightsSHA256(artifact.Weights)
	if err != nil {
		return training.DiagnosticsSummary{}, err
	}
	d.PublishedWeightsSHA256 = publishedHash
	summary, err := training.WriteDiagnostics(path, d)
	if err != nil {
		return training.DiagnosticsSummary{}, err
	}
	if !summary.Equivalent {
		return summary, fmt.Errorf("candidate SGD differs from sequential reference (max %.12g, tolerance abs %.12g rel %.12g)", summary.CandidateMaxDifference, summary.AbsoluteTolerance, summary.RelativeTolerance)
	}
	return summary, nil
}

func distributed(ctx context.Context, c ml.Config, needCandidate bool) (training.Artifact, training.Run, training.Candidate, error) {
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
		return artifact, run, training.Candidate{}, err
	}
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return artifact, run, training.Candidate{}, ctx.Err()
		case <-ticker.C:
			if err := call("GET", "/runs/"+run.ID, nil, &run); err != nil {
				return artifact, run, training.Candidate{}, err
			}
			if run.Status == "failed" {
				return artifact, run, training.Candidate{}, fmt.Errorf("run %s failed: %s", run.ID, run.Error)
			}
			if run.Status == "completed" {
				if err := call("GET", "/models/"+run.ArtifactVersion, nil, &artifact); err != nil {
					return artifact, run, training.Candidate{}, err
				}
				if !needCandidate {
					return artifact, run, training.Candidate{}, nil
				}
				var candidate training.Candidate
				if err := call("GET", "/runs/"+run.ID+"/candidate", nil, &candidate); err != nil {
					return artifact, run, candidate, fmt.Errorf("candidate diagnostics unavailable: %w", err)
				}
				return artifact, run, candidate, nil
			}
		}
	}
}
