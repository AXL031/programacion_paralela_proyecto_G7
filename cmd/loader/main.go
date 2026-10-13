package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/config"
	"github.com/proyecto-g7/transporte/internal/loader"
	"github.com/proyecto-g7/transporte/internal/storage"
	"github.com/proyecto-g7/transporte/internal/storage/files"
	mongostore "github.com/proyecto-g7/transporte/internal/storage/mongo"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "loader:", err)
		os.Exit(1)
	}
}
func run() error {
	path := flag.String("config", "configs/demo.json", "loader config path")
	backend := flag.String("storage", "", "override mongo/files storage")
	workers := flag.Int("workers", 0, "override worker count (1 is sequential reference)")
	flag.Parse()
	c, err := config.Read(*path)
	if err != nil {
		return err
	}
	if *backend != "" {
		c.Storage = *backend
	}
	if *workers != 0 {
		c.Workers = *workers
	}
	if err := c.Validate(); err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	var store storage.Store
	if c.Storage == "files" {
		store = &files.Store{Root: c.Output}
	} else {
		store, err = mongostore.New(ctx, c.MongoURI, c.MongoDatabase)
		if err != nil {
			return err
		}
	}
	result, loadErr := loader.Run(ctx, c, store)
	closeErr := store.Close(context.Background())
	if loadErr != nil {
		return loadErr
	}
	if closeErr != nil {
		return closeErr
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(result)
}
