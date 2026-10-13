package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/api"
	"github.com/proyecto-g7/transporte/internal/ml"
	mongostore "github.com/proyecto-g7/transporte/internal/storage/mongo"
	"github.com/redis/go-redis/v9"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
func main() {
	if err := run(); err != nil {
		slog.Error("api stopped", "error", err)
		os.Exit(1)
	}
}
func run() error {
	check := flag.Bool("check-ready", false, "probe running local API readiness")
	flag.Parse()
	if *check {
		client := http.Client{Timeout: 4 * time.Second}
		res, err := client.Get("http://127.0.0.1:8080/health/ready")
		if err != nil {
			return err
		}
		res.Body.Close()
		if res.StatusCode != 200 {
			return fmt.Errorf("readiness status %d", res.StatusCode)
		}
		return nil
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	startup, stop := context.WithTimeout(ctx, 10*time.Second)
	data, err := mongostore.New(startup, env("MONGO_URI", "mongodb://mongo:27017"), env("MONGO_DATABASE", "transporte"))
	stop()
	if err != nil {
		return err
	}
	defer data.Close(context.Background())
	cache := redis.NewClient(&redis.Options{Addr: env("REDIS_ADDR", "redis:6379"), DialTimeout: 30 * time.Millisecond, ReadTimeout: 30 * time.Millisecond, WriteTimeout: 30 * time.Millisecond, MaxRetries: -1, ContextTimeoutEnabled: true})
	defer cache.Close()
	runtime := api.NewRuntime(data, api.RedisCache{Client: cache})
	runtime.Start(ctx)
	var trainingConfig ml.Config
	raw, err := os.ReadFile("configs/training.json")
	if err != nil {
		return err
	}
	if err := json.Unmarshal(raw, &trainingConfig); err != nil {
		return err
	}
	if err := trainingConfig.Validate(); err != nil {
		return err
	}
	auth, err := api.NewAuth(os.Getenv("JWT_SECRET"), os.Getenv("DEMO_USER"), os.Getenv("DEMO_PASSWORD"), env("WEB_ORIGIN", "http://127.0.0.1:3000"), env("AUTH_SECURE_COOKIE", "false") == "true")
	if err != nil {
		return err
	}
	if len(os.Getenv("MASTER_API_TOKEN")) < 32 {
		return fmt.Errorf("MASTER_API_TOKEN required")
	}
	server := &http.Server{Addr: env("HTTP_ADDR", ":8080"), Handler: api.New(data, func(ctx context.Context) error { return cache.Ping(ctx).Err() }, api.Options{Runtime: runtime, MasterURL: env("MASTER_HTTP", "http://master:8081"), MasterToken: os.Getenv("MASTER_API_TOKEN"), Auth: auth, Context: ctx, TrainingConfig: trainingConfig}), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		server.Shutdown(shutdown)
	}()
	slog.Info("API listening", "address", server.Addr)
	err = server.ListenAndServe()
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}
