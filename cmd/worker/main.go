package main

import (
	"context"
	"flag"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/cluster/worker"
	"github.com/proyecto-g7/transporte/internal/telemetry"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
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
		slog.Error("worker stopped", "error", err)
		os.Exit(1)
	}
}
func run() error {
	check := flag.Bool("check-ready", false, "health probe")
	flag.Parse()
	if *check {
		c := http.Client{Timeout: 3 * time.Second}
		r, err := c.Get("http://127.0.0.1:8082/health/ready")
		if err != nil {
			return err
		}
		r.Body.Close()
		if r.StatusCode != 200 {
			return fmt.Errorf("worker not registered")
		}
		return nil
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	hostname, err := os.Hostname()
	if err != nil {
		return err
	}
	c := &worker.Client{ID: env("WORKER_ID", hostname), Address: env("MASTER_ADDR", "master:9000"), DataRoot: env("DATA_ROOT", "data"), Monitor: telemetry.New(ctx)}
	go func() { c.Run(ctx) }()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/ready", func(w http.ResponseWriter, r *http.Request) {
		if !c.Ready.Load() {
			w.WriteHeader(503)
		} else {
			w.WriteHeader(200)
		}
	})
	h := &http.Server{Addr: ":8082", Handler: mux, ReadHeaderTimeout: 3 * time.Second, WriteTimeout: 3 * time.Second}
	go func() {
		<-ctx.Done()
		stop, done := context.WithTimeout(context.Background(), 3*time.Second)
		defer done()
		h.Shutdown(stop)
	}()
	err = h.ListenAndServe()
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}
