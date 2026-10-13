package loader

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	_ "time/tzdata"

	"github.com/proyecto-g7/transporte/internal/config"
	"github.com/proyecto-g7/transporte/internal/domain"
	"github.com/proyecto-g7/transporte/internal/features"
	"github.com/proyecto-g7/transporte/internal/storage"
)

const ProcessingVersion = "yellow-clean-v1"

func FileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

type Result struct {
	Manifest domain.Manifest `json:"manifest"`
	Reused   bool            `json:"reused"`
}

func Run(ctx context.Context, c config.Loader, store storage.Store) (result Result, err error) {
	if err := c.Validate(); err != nil {
		return result, err
	}
	started := time.Now()
	sourceHash, err := FileSHA256(c.Input)
	if err != nil {
		return result, err
	}
	if c.SHA256File != "" {
		b, e := os.ReadFile(c.SHA256File)
		if e != nil {
			return result, e
		}
		if strings.TrimSpace(string(b)) != sourceHash {
			return result, fmt.Errorf("source checksum mismatch")
		}
	}
	catalogHash, err := FileSHA256(c.ZoneCatalog)
	if err != nil {
		return result, err
	}
	if c.ZoneSHA256File != "" {
		b, e := os.ReadFile(c.ZoneSHA256File)
		if e != nil {
			return result, e
		}
		if strings.TrimSpace(string(b)) != catalogHash {
			return result, fmt.Errorf("zone catalog checksum mismatch")
		}
	}
	zones, err := ReadZones(c.ZoneCatalog)
	if err != nil {
		return result, err
	}
	start, end, loc, err := c.Period()
	if err != nil {
		return result, err
	}
	if int64(end.Sub(start)/(time.Duration(c.WindowMinutes)*time.Minute))*int64(len(zones)) > 2000000 {
		return result, fmt.Errorf("snapshot exceeds 2,000,000 windows; split the period")
	}
	identity := fmt.Sprintf("%s|%s|%s|%s|%s|%d|%s|%s", sourceHash, catalogHash, start.UTC().Format(time.RFC3339), end.UTC().Format(time.RFC3339), c.Timezone, c.WindowMinutes, c.Format, ProcessingVersion)
	h := sha256.Sum256([]byte(identity))
	datasetID := "ds-" + hex.EncodeToString(h[:16])
	existing, err := store.FindComplete(ctx, datasetID)
	if err != nil {
		return result, err
	}
	if existing != nil {
		checksum, e := FileSHA256(filepath.FromSlash(existing.Snapshot.Path))
		if e != nil {
			return result, fmt.Errorf("published snapshot unavailable: %w", e)
		}
		if checksum != existing.Snapshot.SHA256 {
			return result, fmt.Errorf("published snapshot checksum mismatch")
		}
		if err := store.Complete(ctx, *existing); err != nil {
			return result, err
		}
		return Result{Manifest: *existing, Reused: true}, nil
	}
	var token [12]byte
	if _, err := rand.Read(token[:]); err != nil {
		return result, err
	}
	m := domain.Manifest{ID: datasetID, Name: c.Name, LoadID: hex.EncodeToString(token[:]), Status: "loading", Source: c.Source, SourceURL: c.SourceURL, SourceSHA256: sourceHash, CatalogSHA256: catalogHash, Format: c.Format, Timezone: c.Timezone, Start: start.UTC(), End: end.UTC(), WindowMinutes: c.WindowMinutes, ProcessingVersion: ProcessingVersion, CreatedAt: time.Now().UTC(), Zones: zones, Stats: domain.Stats{Rejections: map[string]int64{}}}
	if err := store.Begin(ctx, m); err != nil {
		return result, err
	}
	defer func() {
		if err != nil {
			m.Status = "failed"
			m.Error = err.Error()
			failedCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if e := store.Fail(failedCtx, m); e != nil {
				err = fmt.Errorf("%w; failed to record load failure: %v", err, e)
			}
			result.Manifest = m
		}
	}()
	source, err := OpenSource(c.Input, c.Format, c.BlockRows)
	if err != nil {
		return result, err
	}
	defer source.Close()
	zoneSet := map[int]bool{}
	for _, z := range zones {
		zoneSet[z.ID] = true
	}
	counts := map[features.Key]int64{}
	m.Stats, err = process(ctx, source, c, loc, start, end, zoneSet, m.ID, m.LoadID, store, counts)
	if err != nil {
		return result, err
	}
	if m.Stats.Accepted == 0 {
		return result, fmt.Errorf("no valid trips in selected period")
	}
	// Do not publish a checksum for a source that changed during ingestion.
	after, err := FileSHA256(c.Input)
	if err != nil {
		return result, err
	}
	if after != sourceHash {
		return result, fmt.Errorf("source changed during ingestion")
	}
	dir := filepath.Join(c.Output, m.ID, m.LoadID)
	m.Snapshot, err = features.Export(ctx, m, counts, dir, c.BatchRows, store.WriteWindows)
	if err != nil {
		return result, err
	}
	m.Stats.ElapsedSeconds = time.Since(started).Seconds()
	m.Stats.RowsPerSecond = float64(m.Stats.Read) / m.Stats.ElapsedSeconds
	m.Status = "complete"
	m.CompletedAt = time.Now().UTC()
	if err := store.Complete(ctx, m); err != nil {
		return result, err
	}
	return Result{Manifest: m}, nil
}

type blockResult struct {
	trips []domain.Trip
	stats domain.Stats
}

func process(parent context.Context, source Source, c config.Loader, loc *time.Location, start, end time.Time, zones map[int]bool, datasetID, loadID string, store storage.Store, counts map[features.Key]int64) (domain.Stats, error) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	jobs := make(chan []domain.RawTrip, c.Workers*2)
	results := make(chan blockResult, c.Workers*2)
	sourceErr := make(chan error, 1)
	go func() {
		defer close(jobs)
		sourceErr <- source.Read(ctx, func(rows []domain.RawTrip) error {
			select {
			case jobs <- rows:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
	}()
	var wg sync.WaitGroup
	for i := 0; i < c.Workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for rows := range jobs {
				if ctx.Err() != nil {
					return
				}
				b := blockResult{trips: make([]domain.Trip, 0, len(rows)), stats: domain.Stats{Read: int64(len(rows)), Rejections: map[string]int64{}}}
				for _, r := range rows {
					t, reason := validate(r, loc, start, end, zones, datasetID, loadID)
					switch reason {
					case "":
						b.trips = append(b.trips, t)
						b.stats.Accepted++
					case "outside_period":
						b.stats.OutsidePeriod++
					default:
						b.stats.Rejected++
						b.stats.Rejections[reason]++
					}
				}
				select {
				case results <- b:
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	go func() { wg.Wait(); close(results) }()
	stats := domain.Stats{Rejections: map[string]int64{}}
	batch := make([]domain.Trip, 0, c.BatchRows)
	var failure error
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		if err := store.WriteTrips(ctx, batch); err != nil {
			return err
		}
		stats.Persisted += int64(len(batch))
		batch = make([]domain.Trip, 0, c.BatchRows)
		return nil
	}
	windowSeconds := int64(c.WindowMinutes * 60)
	for b := range results {
		if failure != nil {
			continue
		}
		stats.Read += b.stats.Read
		stats.Accepted += b.stats.Accepted
		stats.Rejected += b.stats.Rejected
		stats.OutsidePeriod += b.stats.OutsidePeriod
		for k, v := range b.stats.Rejections {
			stats.Rejections[k] += v
		}
		for _, t := range b.trips {
			key := features.Key{Zone: t.PickupZone, Unix: t.Pickup.Unix() / windowSeconds * windowSeconds}
			counts[key]++
			batch = append(batch, t)
			if len(batch) == c.BatchRows {
				if e := flush(); e != nil {
					failure = e
					cancel()
					break
				}
			}
		}
	}
	readErr := <-sourceErr
	if failure != nil {
		return stats, failure
	}
	if readErr != nil {
		return stats, readErr
	}
	if err := ctx.Err(); err != nil {
		return stats, err
	}
	if err := flush(); err != nil {
		return stats, err
	}
	if stats.Read != stats.Accepted+stats.Rejected+stats.OutsidePeriod || stats.Accepted != stats.Persisted {
		return stats, fmt.Errorf("row accounting invariant failed")
	}
	return stats, nil
}
