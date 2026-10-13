package loader

import (
	"context"
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/parquet-go/parquet-go"
	"github.com/proyecto-g7/transporte/internal/domain"
)

type Source interface {
	Read(context.Context, func([]domain.RawTrip) error) error
	Close() error
}

type csvSource struct {
	f     *os.File
	block int
}
type parquetSource struct {
	f     *os.File
	block int
}

func OpenSource(path, format string, block int) (Source, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	if format == "csv" {
		return &csvSource{f, block}, nil
	}
	if format == "parquet" {
		return &parquetSource{f, block}, nil
	}
	f.Close()
	return nil, fmt.Errorf("unsupported format %q", format)
}
func (s *csvSource) Close() error     { return s.f.Close() }
func (s *parquetSource) Close() error { return s.f.Close() }

func (s *csvSource) Read(ctx context.Context, emit func([]domain.RawTrip) error) error {
	r := csv.NewReader(s.f)
	r.FieldsPerRecord = -1
	header, err := r.Read()
	if err != nil {
		return fmt.Errorf("CSV header: %w", err)
	}
	cols := map[string]int{}
	for i, h := range header {
		h = strings.TrimPrefix(h, "\uFEFF")
		if _, exists := cols[h]; exists {
			return fmt.Errorf("duplicate CSV column %s", h)
		}
		cols[h] = i
	}
	for _, h := range []string{"tpep_pickup_datetime", "tpep_dropoff_datetime", "PULocationID", "DOLocationID", "trip_distance"} {
		if _, ok := cols[h]; !ok {
			return fmt.Errorf("missing CSV column %s", h)
		}
	}
	rows := make([]domain.RawTrip, 0, s.block)
	var ordinal int64
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		record, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("CSV structural error after row %d: %w", ordinal, err)
		}
		ordinal++
		x := domain.RawTrip{Ordinal: ordinal}
		if len(record) != len(header) {
			x.ParseError = "column_count"
		} else {
			x.Pickup = record[cols["tpep_pickup_datetime"]]
			x.Dropoff = record[cols["tpep_dropoff_datetime"]]
			var a, b, c error
			x.PickupZone, a = strconv.Atoi(record[cols["PULocationID"]])
			x.DropoffZone, b = strconv.Atoi(record[cols["DOLocationID"]])
			x.Distance, c = strconv.ParseFloat(record[cols["trip_distance"]], 64)
			if a != nil || b != nil || c != nil {
				x.ParseError = "numeric_field"
			}
		}
		rows = append(rows, x)
		if len(rows) == s.block {
			if err := emit(rows); err != nil {
				return err
			}
			rows = make([]domain.RawTrip, 0, s.block)
		}
	}
	if len(rows) > 0 {
		return emit(rows)
	}
	return nil
}

// TLC timestamps encode local wall time, not a reliable UTC instant.
type yellowRow struct {
	Pickup   *int64   `parquet:"tpep_pickup_datetime,optional,timestamp(microsecond)"`
	Dropoff  *int64   `parquet:"tpep_dropoff_datetime,optional,timestamp(microsecond)"`
	PU       *int64   `parquet:"PULocationID,optional"`
	DO       *int64   `parquet:"DOLocationID,optional"`
	Distance *float64 `parquet:"trip_distance,optional"`
}

func (s *parquetSource) Read(ctx context.Context, emit func([]domain.RawTrip) error) (err error) {
	// Schema mismatch must become an explicit failed load rather than a panic.
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("Parquet schema/decoder: %v", p)
		}
	}()
	info, err := s.f.Stat()
	if err != nil {
		return err
	}
	pf, err := parquet.OpenFile(s.f, info.Size())
	if err != nil {
		return err
	}
	cols := map[string]bool{}
	for _, p := range pf.Schema().Columns() {
		if len(p) == 1 {
			cols[p[0]] = true
		}
	}
	for _, name := range []string{"tpep_pickup_datetime", "tpep_dropoff_datetime", "PULocationID", "DOLocationID", "trip_distance"} {
		if !cols[name] {
			return fmt.Errorf("missing Parquet column %s", name)
		}
	}
	r := parquet.NewGenericReader[yellowRow](pf)
	defer r.Close()
	buf := make([]yellowRow, s.block)
	var ordinal int64
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		n, readErr := r.Read(buf)
		if n > 0 {
			rows := make([]domain.RawTrip, n)
			for i, v := range buf[:n] {
				ordinal++
				x := domain.RawTrip{Ordinal: ordinal}
				if v.Pickup == nil || v.Dropoff == nil || v.PU == nil || v.DO == nil || v.Distance == nil {
					x.ParseError = "missing_field"
				} else {
					x.Pickup = time.UnixMicro(*v.Pickup).UTC().Format("2006-01-02 15:04:05.999999")
					x.Dropoff = time.UnixMicro(*v.Dropoff).UTC().Format("2006-01-02 15:04:05.999999")
					x.PickupZone = int(*v.PU)
					x.DropoffZone = int(*v.DO)
					x.Distance = *v.Distance
				}
				rows[i] = x
			}
			if err := emit(rows); err != nil {
				return err
			}
		}
		if readErr == io.EOF {
			return nil
		}
		if readErr != nil {
			return readErr
		}
		if n == 0 {
			return io.ErrNoProgress
		}
	}
}

func ReadZones(path string) ([]domain.Zone, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	r := csv.NewReader(f)
	h, err := r.Read()
	if err != nil {
		return nil, err
	}
	cols := map[string]int{}
	for i, k := range h {
		cols[k] = i
	}
	for _, k := range []string{"LocationID", "Borough", "Zone"} {
		if _, ok := cols[k]; !ok {
			return nil, fmt.Errorf("missing zone column %s", k)
		}
	}
	var zones []domain.Zone
	seen := map[int]bool{}
	for {
		row, e := r.Read()
		if e == io.EOF {
			break
		}
		if e != nil {
			return nil, e
		}
		id, e := strconv.Atoi(row[cols["LocationID"]])
		if e != nil {
			return nil, e
		}
		if id < 1 || id > 263 {
			continue
		}
		if seen[id] {
			return nil, fmt.Errorf("duplicate zone %d", id)
		}
		seen[id] = true
		zones = append(zones, domain.Zone{ID: id, Borough: row[cols["Borough"]], Name: row[cols["Zone"]]})
	}
	if len(zones) == 0 {
		return nil, fmt.Errorf("empty zone catalog")
	}
	return zones, nil
}
