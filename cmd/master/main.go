package main

import (
	"context"
	"flag"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/cluster/master"
	mongostore "github.com/proyecto-g7/transporte/internal/storage/mongo"
	"log/slog"
	"net"
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
		slog.Error("master stopped", "error", err)
		os.Exit(1)
	}
}
func run() error {
	check := flag.Bool("check-ready", false, "health probe")
	flag.Parse()
	if *check {
		c := http.Client{Timeout: 4 * time.Second}
		r, err := c.Get("http://127.0.0.1:8081/health/ready")
		if err != nil {
			return err
		}
		r.Body.Close()
		if r.StatusCode != 200 {
			return fmt.Errorf("master not ready")
		}
		return nil
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	repo, err := mongostore.New(ctx, env("MONGO_URI", "mongodb://mongo:27017"), env("MONGO_DATABASE", "transporte"))
	if err != nil {
		return err
	}
	defer repo.Close(context.Background())
	if err := repo.RecoverInterrupted(ctx); err != nil {
		return err
	}
	listener, err := net.Listen("tcp", env("TCP_ADDR", ":9000"))
	if err != nil {
		return err
	}
	defer listener.Close()
	s := master.New(ctx, repo)
	s.Secret = os.Getenv("MASTER_API_TOKEN")
	if len(s.Secret) < 32 {
		return fmt.Errorf("MASTER_API_TOKEN required")
	}
	go func() {
		if err := s.Serve(listener); err != nil {
			slog.Error("TCP listener failed", "error", err)
			cancel()
		}
	}()
	h := &http.Server{Addr: env("MASTER_HTTP_ADDR", ":8081"), Handler: s.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second}
	go func() {
		<-ctx.Done()
		stop, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		h.Shutdown(stop)
	}()
	slog.Info("master listening", "tcp", listener.Addr(), "http", h.Addr)
	err = h.ListenAndServe()
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}
