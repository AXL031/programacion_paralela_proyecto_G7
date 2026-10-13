package features

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/domain"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"time"
)

type Key struct {
	Zone int
	Unix int64
}
type Example struct {
	ZoneID      int       `json:"zone_id"`
	Origin      time.Time `json:"forecast_origin"`
	TargetStart time.Time `json:"target_start"`
	HourSin     float64   `json:"hour_sin"`
	HourCos     float64   `json:"hour_cos"`
	DayOfWeek   int       `json:"day_of_week"`
	Weekend     bool      `json:"weekend"`
	Lag1        int64     `json:"lag1_count"`
	Target      int64     `json:"target_count"`
	Split       string    `json:"split"`
}

// Export traverses fixed time/zone order; worker completion order cannot change the snapshot.
func Export(ctx context.Context, m domain.Manifest, counts map[Key]int64, dir string, batchSize int, write func(context.Context, []domain.Window) error) (domain.Snapshot, error) {
	if err := os.MkdirAll(dir, 0755); err != nil {
		return domain.Snapshot{}, err
	}
	wf, err := os.Create(filepath.Join(dir, "windows.ndjson"))
	if err != nil {
		return domain.Snapshot{}, err
	}
	defer wf.Close()
	ff, err := os.Create(filepath.Join(dir, "features.ndjson"))
	if err != nil {
		return domain.Snapshot{}, err
	}
	defer ff.Close()
	hash := sha256.New()
	wb := bufio.NewWriterSize(wf, 256*1024)
	fb := bufio.NewWriterSize(io.MultiWriter(ff, hash), 256*1024)
	we, fe := json.NewEncoder(wb), json.NewEncoder(fb)
	loc, err := time.LoadLocation(m.Timezone)
	if err != nil {
		return domain.Snapshot{}, err
	}
	step := time.Duration(m.WindowMinutes) * time.Minute
	slots := int(m.End.Sub(m.Start) / step)
	if slots < 4 {
		return domain.Snapshot{}, fmt.Errorf("at least four complete windows are needed")
	}
	trainSlots := slots * 70 / 100
	validSlots := slots * 85 / 100
	s := domain.Snapshot{Version: "raw-counts-v1", Path: filepath.ToSlash(filepath.Join(dir, "features.ndjson")), FeatureNames: []string{"zone_id:categorical", "hour_sin", "hour_cos", "day_of_week:categorical", "weekend", "lag1_count"}, TrainEnd: m.Start.Add(time.Duration(trainSlots) * step), ValidationEnd: m.Start.Add(time.Duration(validSlots) * step), Normalization: "raw; fit normalizer on train only in step 4", Splits: map[string]int64{"train": 0, "validation": 0, "test": 0}}
	zones := append([]domain.Zone(nil), m.Zones...)
	sort.Slice(zones, func(i, j int) bool { return zones[i].ID < zones[j].ID })
	batch := make([]domain.Window, 0, batchSize)
	for index := 0; index < slots; index++ {
		if err := ctx.Err(); err != nil {
			return s, err
		}
		t := m.Start.Add(time.Duration(index) * step).UTC()
		local := t.In(loc)
		fraction := (float64(local.Hour()) + float64(local.Minute())/60) / 24
		for _, zone := range zones {
			count := counts[Key{zone.ID, t.Unix()}]
			w := domain.Window{ID: fmt.Sprintf("%s:%d:%d", m.LoadID, zone.ID, t.Unix()), DatasetID: m.ID, LoadID: m.LoadID, ZoneID: zone.ID, Start: t, Count: count, Coverage: "accepted_records_in_source_file"}
			if err := we.Encode(w); err != nil {
				return s, err
			}
			batch = append(batch, w)
			s.Windows++
			if len(batch) == batchSize {
				if err := write(ctx, batch); err != nil {
					return s, err
				}
				batch = make([]domain.Window, 0, batchSize)
			}
			if index == 0 {
				continue
			}
			split := "test"
			if index < trainSlots {
				split = "train"
			} else if index < validSlots {
				split = "validation"
			}
			ex := Example{ZoneID: zone.ID, Origin: t, TargetStart: t, HourSin: math.Sin(2 * math.Pi * fraction), HourCos: math.Cos(2 * math.Pi * fraction), DayOfWeek: int(local.Weekday()), Weekend: local.Weekday() == time.Saturday || local.Weekday() == time.Sunday, Lag1: counts[Key{zone.ID, t.Add(-step).Unix()}], Target: count, Split: split}
			// Origin is the boundary just before the target begins; lag1 is the completed previous window.
			if err := fe.Encode(ex); err != nil {
				return s, err
			}
			s.Examples++
			s.Splits[split]++
		}
	}
	if len(batch) > 0 {
		if err := write(ctx, batch); err != nil {
			return s, err
		}
	}
	if err := wb.Flush(); err != nil {
		return s, err
	}
	if err := fb.Flush(); err != nil {
		return s, err
	}
	if err := wf.Sync(); err != nil {
		return s, err
	}
	if err := ff.Sync(); err != nil {
		return s, err
	}
	s.SHA256 = hex.EncodeToString(hash.Sum(nil))
	return s, nil
}
