package main

import (
	"context"
	"flag"
	"fmt"
	"github.com/proyecto-g7/transporte/web"
	"io/fs"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
		slog.Error("web stopped", "error", err)
		os.Exit(1)
	}
}
func run() error {
	check := flag.Bool("check-ready", false, "health probe")
	flag.Parse()
	if *check {
		c := http.Client{Timeout: 3 * time.Second}
		r, e := c.Get("http://127.0.0.1:3000/health/live")
		if e != nil {
			return e
		}
		r.Body.Close()
		if r.StatusCode != 200 {
			return fmt.Errorf("web unavailable")
		}
		return nil
	}
	target := os.Getenv("API_UPSTREAM")
	if target == "" {
		target = "http://api:8080"
	}
	u, err := url.Parse(target)
	if err != nil || u.Host == "" {
		return fmt.Errorf("invalid API_UPSTREAM")
	}
	proxy := httputil.NewSingleHostReverseProxy(u)
	proxy.Transport = &http.Transport{ResponseHeaderTimeout: 12 * time.Second}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, e error) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(503)
		w.Write([]byte(`{"error":"La API no está disponible. Inténtalo nuevamente."}`))
	}
	assets, err := fs.Sub(web.Assets, "dist")
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.Handle("/api/", proxy)
	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.Handle("/", http.FileServer(http.FS(assets)))
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	server := &http.Server{Addr: ":3000", Handler: mux, ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 20 * time.Second, IdleTimeout: 60 * time.Second}
	go func() {
		<-ctx.Done()
		c, stop := context.WithTimeout(context.Background(), 3*time.Second)
		defer stop()
		server.Shutdown(c)
	}()
	err = server.ListenAndServe()
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}
