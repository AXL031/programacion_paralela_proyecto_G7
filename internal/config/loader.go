package config

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

type Loader struct {
	Name           string `json:"name"`
	Source         string `json:"source"`
	SourceURL      string `json:"source_url"`
	Input          string `json:"input"`
	Format         string `json:"format"`
	SHA256File     string `json:"sha256_file"`
	ZoneSHA256File string `json:"zone_sha256_file"`
	ZoneCatalog    string `json:"zone_catalog"`
	Timezone       string `json:"timezone"`
	PeriodStart    string `json:"period_start"`
	PeriodEnd      string `json:"period_end_exclusive"`
	WindowMinutes  int    `json:"window_minutes"`
	Workers        int    `json:"workers"`
	BlockRows      int    `json:"block_rows"`
	BatchRows      int    `json:"batch_rows"`
	Storage        string `json:"storage"`
	Output         string `json:"output"`
	MongoURI       string `json:"mongo_uri"`
	MongoDatabase  string `json:"mongo_database"`
}

func Read(path string) (Loader, error) {
	f, err := os.Open(path)
	if err != nil {
		return Loader{}, err
	}
	defer f.Close()
	var c Loader
	d := json.NewDecoder(f)
	d.DisallowUnknownFields()
	if err := d.Decode(&c); err != nil {
		return c, err
	}
	if err := d.Decode(&struct{}{}); err != io.EOF {
		return c, fmt.Errorf("config must contain one JSON object")
	}
	if uri := os.Getenv("MONGO_URI"); uri != "" {
		c.MongoURI = uri
	}
	if db := os.Getenv("MONGO_DATABASE"); db != "" {
		c.MongoDatabase = db
	}
	return c, c.Validate()
}

func (c Loader) Period() (time.Time, time.Time, *time.Location, error) {
	l, err := time.LoadLocation(c.Timezone)
	if err != nil {
		return time.Time{}, time.Time{}, nil, err
	}
	start, err := time.Parse(time.RFC3339, c.PeriodStart)
	if err != nil {
		return start, time.Time{}, l, err
	}
	end, err := time.Parse(time.RFC3339, c.PeriodEnd)
	if err != nil {
		return start, end, l, err
	}
	return start, end, l, nil
}

func (c Loader) Validate() error {
	if c.Name == "" || c.Input == "" || c.Output == "" || c.ZoneCatalog == "" || c.Source == "" {
		return fmt.Errorf("name, source, input, output and zone_catalog are required")
	}
	if c.Format != "csv" && c.Format != "parquet" {
		return fmt.Errorf("format must be csv or parquet")
	}
	if c.Storage != "mongo" && c.Storage != "files" {
		return fmt.Errorf("storage must be mongo or files")
	}
	if c.Workers < 1 || c.Workers > 64 || c.BlockRows < 1 || c.BlockRows > 65536 || c.BatchRows < 1 || c.BatchRows > 10000 {
		return fmt.Errorf("invalid worker/block/batch limits")
	}
	if c.Workers*c.BlockRows > 1048576 {
		return fmt.Errorf("worker/block combination exceeds memory budget")
	}
	if c.WindowMinutes < 1 || 60%c.WindowMinutes != 0 {
		return fmt.Errorf("window_minutes must divide 60")
	}
	s, e, _, err := c.Period()
	if err != nil {
		return err
	}
	w := time.Duration(c.WindowMinutes) * time.Minute
	if !e.After(s) || e.Sub(s) > 366*24*time.Hour || s.Unix()%int64(w.Seconds()) != 0 || e.Unix()%int64(w.Seconds()) != 0 {
		return fmt.Errorf("period must be ordered, aligned to windows, and at most 366 days")
	}
	if c.Storage == "mongo" && (!strings.HasPrefix(c.MongoURI, "mongodb://") && !strings.HasPrefix(c.MongoURI, "mongodb+srv://") || c.MongoDatabase == "") {
		return fmt.Errorf("valid mongo_uri and mongo_database are required")
	}
	return nil
}
