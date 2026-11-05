package loader

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/parquet-go/parquet-go"
	"github.com/proyecto-g7/transporte/internal/config"
	"github.com/proyecto-g7/transporte/internal/domain"
	"github.com/proyecto-g7/transporte/internal/features"
	"github.com/proyecto-g7/transporte/internal/storage/files"
)

func fixtureConfig(t *testing.T, workers int) config.Loader {
	t.Helper()
	repo := filepath.Join("..", "..")
	return config.Loader{Name: "fixture", Source: "synthetic test fixture", Input: filepath.Join(repo, "tests", "testdata", "trips.csv"), Format: "csv", ZoneCatalog: filepath.Join(repo, "tests", "testdata", "zones.csv"), Timezone: "America/New_York", PeriodStart: "2024-01-01T00:00:00-05:00", PeriodEnd: "2024-01-02T00:00:00-05:00", WindowMinutes: 15, Workers: workers, BlockRows: 2, BatchRows: 2, Storage: "files", Output: t.TempDir()}
}
func runWithOptions(t *testing.T, c config.Loader, opts RunOptions) (Result, error) {
	t.Helper()
	s := &files.Store{Root: c.Output}
	r, err := RunWithOptions(context.Background(), c, s, opts)
	closeErr := s.Close(context.Background())
	if err == nil && closeErr != nil {
		t.Fatal(closeErr)
	}
	return r, err
}

func execute(t *testing.T, c config.Loader) Result {
	t.Helper()
	r, err := runWithOptions(t, c, RunOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func readTrips(t *testing.T, path string) []domain.Trip {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var trips []domain.Trip
	dec := json.NewDecoder(f)
	for {
		var trip domain.Trip
		err := dec.Decode(&trip)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		trips = append(trips, trip)
	}
	sort.Slice(trips, func(i, j int) bool { return trips[i].SourceRow < trips[j].SourceRow })
	return trips
}

func readWindows(t *testing.T, path string) []domain.Window {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var windows []domain.Window
	dec := json.NewDecoder(f)
	for {
		var window domain.Window
		err := dec.Decode(&window)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		windows = append(windows, window)
	}
	sort.Slice(windows, func(i, j int) bool {
		if windows[i].Start.Equal(windows[j].Start) {
			return windows[i].ZoneID < windows[j].ZoneID
		}
		return windows[i].Start.Before(windows[j].Start)
	})
	return windows
}

func countLines(t *testing.T, path string) int {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	count := 0
	for scanner.Scan() {
		count++
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	return count
}

func normalizedTrips(trips []domain.Trip) []domain.Trip {
	out := append([]domain.Trip(nil), trips...)
	for i := range out {
		out[i].ID = ""
		out[i].LoadID = ""
	}
	return out
}

func normalizedWindows(windows []domain.Window) []domain.Window {
	out := append([]domain.Window(nil), windows...)
	for i := range out {
		out[i].ID = ""
		out[i].LoadID = ""
	}
	return out
}

func TestSequentialConcurrentAndIdempotency(t *testing.T) {
	sequential := fixtureConfig(t, 1)
	parallel := sequential
	parallel.Workers = 4
	parallel.Output = t.TempDir()
	a, b := execute(t, sequential), execute(t, parallel)
	for _, r := range []Result{a, b} {
		s := r.Manifest.Stats
		if s.Read != 8 || s.Accepted != 3 || s.Rejected != 4 || s.OutsidePeriod != 1 || s.Persisted != 3 {
			t.Fatalf("unexpected stats: %+v", s)
		}
		if r.Manifest.Snapshot.Windows != 192 || r.Manifest.Snapshot.Examples != 190 {
			t.Fatalf("unexpected snapshot: %+v", r.Manifest.Snapshot)
		}
	}
	if a.Manifest.ID != b.Manifest.ID || a.Manifest.Snapshot.SHA256 != b.Manifest.Snapshot.SHA256 {
		t.Fatal("worker count changed dataset identity or features")
	}
	before, err := os.Stat(filepath.Join(sequential.Output, a.Manifest.ID, a.Manifest.LoadID, "trips.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	reused := execute(t, sequential)
	if !reused.Reused || reused.Manifest.LoadID != a.Manifest.LoadID {
		t.Fatal("completed load was not reused")
	}
	after, err := os.Stat(filepath.Join(sequential.Output, a.Manifest.ID, a.Manifest.LoadID, "trips.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	if before.Size() != after.Size() {
		t.Fatal("reloading appended duplicate trips")
	}
	f, err := os.Open(filepath.FromSlash(a.Manifest.Snapshot.Path))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	decoder := json.NewDecoder(f)
	found := false
	for {
		var ex features.Example
		err := decoder.Decode(&ex)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if ex.ZoneID == 161 && ex.TargetStart.Equal(time.Date(2024, 1, 1, 14, 15, 0, 0, time.UTC)) {
			found = true
			if ex.Lag1 != 2 || ex.Target != 0 {
				t.Fatalf("future data used for lag: %+v", ex)
			}
		}
	}
	if !found {
		t.Fatal("expected zero-count window missing")
	}
}

func TestRejectReuse(t *testing.T) {
	c := fixtureConfig(t, 1)
	first := execute(t, c)

	reused, err := runWithOptions(t, c, RunOptions{RejectReuse: true})
	if !errors.Is(err, ErrReuseRejected) {
		t.Fatalf("expected ErrReuseRejected, got %v", err)
	}
	if reused.Reused || reused.Manifest.ID != "" || reused.Manifest.Stats.Accepted != 0 {
		t.Fatalf("strict mode returned historical result: %+v", reused)
	}

	s := &files.Store{Root: c.Output}
	m, err := s.FindComplete(context.Background(), first.Manifest.ID)
	if err != nil || m == nil {
		t.Fatalf("original completed load was lost: %v", err)
	}
	if m.Status != "complete" || m.LoadID != first.Manifest.LoadID {
		t.Fatalf("strict rejection changed the published load: %+v", m)
	}
}

func TestTimingsConfigurationAndThroughput(t *testing.T) {
	c := fixtureConfig(t, 4)
	r := execute(t, c)
	tm := r.Timings
	if tm.TotalSeconds <= 0 {
		t.Fatalf("total time must be positive: %+v", tm)
	}
	if tm.PreparationSeconds == nil || tm.ComputeSeconds == nil || tm.PublicationSeconds == nil {
		t.Fatalf("load phases were not instrumented: %+v", tm)
	}
	if *tm.PreparationSeconds < 0 || *tm.ComputeSeconds < 0 || *tm.PublicationSeconds < 0 {
		t.Fatalf("negative phase duration: %+v", tm)
	}
	if tm.EvaluationSeconds != nil {
		t.Fatalf("load must report evaluation as null, got %v", *tm.EvaluationSeconds)
	}
	sum := *tm.PreparationSeconds + *tm.ComputeSeconds + *tm.PublicationSeconds
	if math.Abs(sum-tm.TotalSeconds) > 1e-6 {
		t.Fatalf("phases %.9f do not add up to total %.9f", sum, tm.TotalSeconds)
	}

	conf := r.Configuration
	if conf.Workers != 4 || conf.BlockRows != 2 || conf.BatchRows != 2 || conf.Storage != "files" || conf.Format != "csv" || conf.WindowMinutes != 15 || conf.ProcessingVersion != ProcessingVersion {
		t.Fatalf("unexpected configuration: %+v", conf)
	}
	if conf.GOMAXPROCS < 1 {
		t.Fatalf("invalid GOMAXPROCS: %d", conf.GOMAXPROCS)
	}

	stats := r.Manifest.Stats
	if stats.ElapsedSeconds <= 0 || stats.RowsPerSecond <= 0 || stats.AcceptedPerSecond <= 0 {
		t.Fatalf("throughput was not instrumented: %+v", stats)
	}
	if math.Abs(stats.RowsPerSecond-float64(stats.Read)/stats.ElapsedSeconds) > 1e-9 {
		t.Fatalf("wrong source throughput: %+v", stats)
	}
	if math.Abs(stats.AcceptedPerSecond-float64(stats.Accepted)/stats.ElapsedSeconds) > 1e-9 {
		t.Fatalf("wrong accepted throughput: %+v", stats)
	}
}

func TestL1L4LogicalEquivalence(t *testing.T) {
	l1Config := fixtureConfig(t, 1)
	l4Config := fixtureConfig(t, 4)
	l1 := execute(t, l1Config)
	l4 := execute(t, l4Config)

	if l1.Manifest.ID != l4.Manifest.ID {
		t.Fatalf("worker count changed dataset identity: %s != %s", l1.Manifest.ID, l4.Manifest.ID)
	}
	for name, pair := range map[string][2]string{
		"name":               {l1.Manifest.Name, l4.Manifest.Name},
		"source":             {l1.Manifest.Source, l4.Manifest.Source},
		"source_url":         {l1.Manifest.SourceURL, l4.Manifest.SourceURL},
		"source_sha256":      {l1.Manifest.SourceSHA256, l4.Manifest.SourceSHA256},
		"catalog_sha256":     {l1.Manifest.CatalogSHA256, l4.Manifest.CatalogSHA256},
		"format":             {l1.Manifest.Format, l4.Manifest.Format},
		"timezone":           {l1.Manifest.Timezone, l4.Manifest.Timezone},
		"processing_version": {l1.Manifest.ProcessingVersion, l4.Manifest.ProcessingVersion},
		"status":             {l1.Manifest.Status, l4.Manifest.Status},
	} {
		if pair[0] != pair[1] {
			t.Fatalf("%s changed with worker count: %q != %q", name, pair[0], pair[1])
		}
	}
	if l1.Manifest.WindowMinutes != l4.Manifest.WindowMinutes || !l1.Manifest.Start.Equal(l4.Manifest.Start) || !l1.Manifest.End.Equal(l4.Manifest.End) {
		t.Fatalf("period/window changed with worker count")
	}
	if !reflect.DeepEqual(l1.Manifest.Zones, l4.Manifest.Zones) {
		t.Fatalf("zone catalog changed with worker count")
	}

	wantStats := struct {
		read, accepted, rejected, outside, persisted int64
	}{
		read: 8, accepted: 3, rejected: 4, outside: 1, persisted: 3,
	}
	for _, got := range []domain.Stats{l1.Manifest.Stats, l4.Manifest.Stats} {
		if got.Read != wantStats.read || got.Accepted != wantStats.accepted || got.Rejected != wantStats.rejected || got.OutsidePeriod != wantStats.outside || got.Persisted != wantStats.persisted {
			t.Fatalf("unexpected counts: %+v", got)
		}
		wantRejections := map[string]int64{
			"nonpositive_duration": 1,
			"unknown_zone":         1,
			"pickup_datetime":      1,
			"invalid_distance":     1,
		}
		if !reflect.DeepEqual(got.Rejections, wantRejections) {
			t.Fatalf("unexpected rejection causes: %+v", got.Rejections)
		}
	}
	if !reflect.DeepEqual(l1.Manifest.Stats.Rejections, l4.Manifest.Stats.Rejections) {
		t.Fatalf("rejection causes changed with worker count")
	}

	s1, s4 := l1.Manifest.Snapshot, l4.Manifest.Snapshot
	if s1.SHA256 != s4.SHA256 || s1.Windows != s4.Windows || s1.Examples != s4.Examples {
		t.Fatalf("snapshot identity changed with worker count: %+v != %+v", s1, s4)
	}
	if s1.Version != s4.Version || s1.Normalization != s4.Normalization || !s1.TrainEnd.Equal(s4.TrainEnd) || !s1.ValidationEnd.Equal(s4.ValidationEnd) {
		t.Fatalf("snapshot metadata changed with worker count")
	}
	if !reflect.DeepEqual(s1.FeatureNames, s4.FeatureNames) || !reflect.DeepEqual(s1.Splits, s4.Splits) {
		t.Fatalf("snapshot features/splits changed with worker count")
	}
	wantSplits := map[string]int64{"train": 132, "validation": 28, "test": 30}
	if !reflect.DeepEqual(s1.Splits, wantSplits) {
		t.Fatalf("unexpected splits: %+v", s1.Splits)
	}

	features1 := filepath.FromSlash(s1.Path)
	features4 := filepath.FromSlash(s4.Path)
	if got := countLines(t, features1); got != int(s1.Examples) {
		t.Fatalf("feature line count %d != examples %d", got, s1.Examples)
	}
	if got, err := FileSHA256(features1); err != nil || got != s1.SHA256 {
		t.Fatalf("snapshot checksum mismatch: %s %v", got, err)
	}
	featuresBytes1, err := os.ReadFile(features1)
	if err != nil {
		t.Fatal(err)
	}
	featuresBytes4, err := os.ReadFile(features4)
	if err != nil {
		t.Fatal(err)
	}
	if string(featuresBytes1) != string(featuresBytes4) {
		t.Fatal("feature snapshot bytes changed with worker count")
	}

	windows1Path := filepath.Join(filepath.Dir(features1), "windows.ndjson")
	windows4Path := filepath.Join(filepath.Dir(features4), "windows.ndjson")
	if got := countLines(t, windows1Path); got != int(s1.Windows) {
		t.Fatalf("window line count %d != windows %d", got, s1.Windows)
	}
	windows1 := normalizedWindows(readWindows(t, windows1Path))
	windows4 := normalizedWindows(readWindows(t, windows4Path))
	if !reflect.DeepEqual(windows1, windows4) {
		t.Fatal("logical windows changed with worker count")
	}

	trips1 := normalizedTrips(readTrips(t, filepath.Join(l1Config.Output, l1.Manifest.ID, l1.Manifest.LoadID, "trips.ndjson")))
	trips4 := normalizedTrips(readTrips(t, filepath.Join(l4Config.Output, l4.Manifest.ID, l4.Manifest.LoadID, "trips.ndjson")))
	if !reflect.DeepEqual(trips1, trips4) {
		t.Fatal("logical trips changed with worker count")
	}
}

type failingStore struct {
	*files.Store
	Failed bool
}

func (s *failingStore) WriteTrips(context.Context, []domain.Trip) error {
	return errors.New("injected persistence failure")
}
func (s *failingStore) Fail(ctx context.Context, m domain.Manifest) error {
	s.Failed = true
	return s.Store.Fail(ctx, m)
}

func TestPersistenceFailureDoesNotPublish(t *testing.T) {
	c := fixtureConfig(t, 4)
	s := &failingStore{Store: &files.Store{Root: c.Output}}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	r, err := Run(ctx, c, s)
	s.Close(context.Background())
	if err == nil || !strings.Contains(err.Error(), "injected persistence") || !s.Failed {
		t.Fatalf("failure was lost: %v", err)
	}
	if r.Manifest.Status != "failed" {
		t.Fatal("failed load not recorded")
	}
	m, err := s.FindComplete(context.Background(), r.Manifest.ID)
	if err != nil || m != nil {
		t.Fatal("partial data published")
	}
}

func TestStructuralCSVErrorDoesNotPublish(t *testing.T) {
	c := fixtureConfig(t, 2)
	c.Input = filepath.Join(t.TempDir(), "broken.csv")
	os.WriteFile(c.Input, []byte("tpep_pickup_datetime,tpep_dropoff_datetime,PULocationID,DOLocationID,trip_distance\n\"unterminated"), 0600)
	s := &files.Store{Root: c.Output}
	r, err := Run(context.Background(), c, s)
	s.Close(context.Background())
	if err == nil || r.Manifest.Status != "failed" {
		t.Fatalf("malformed CSV was accepted: %v", err)
	}
}

func TestParquetMatchesCSV(t *testing.T) {
	c := fixtureConfig(t, 2)
	c.Input = filepath.Join(t.TempDir(), "fixture.parquet")
	c.Format = "parquet"
	stamp := func(v string) *int64 {
		x, err := time.Parse("2006-01-02 15:04:05", v)
		if err != nil {
			t.Fatal(err)
		}
		n := x.UnixMicro()
		return &n
	}
	pu, do := int64(161), int64(162)
	distance := 1.2
	rows := []yellowRow{{Pickup: stamp("2024-01-01 09:00:00"), Dropoff: stamp("2024-01-01 09:10:00"), PU: &pu, DO: &do, Distance: &distance}, {Pickup: nil, Dropoff: stamp("2024-01-01 09:10:00"), PU: &pu, DO: &do, Distance: &distance}}
	if err := parquet.WriteFile(c.Input, rows); err != nil {
		t.Fatal(err)
	}
	r := execute(t, c)
	if r.Manifest.Stats.Accepted != 1 || r.Manifest.Stats.Rejections["missing_field"] != 1 {
		t.Fatalf("incorrect Parquet stats: %+v", r.Manifest.Stats)
	}
	b, err := os.ReadFile(filepath.Join(c.Output, r.Manifest.ID, r.Manifest.LoadID, "trips.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	var trip domain.Trip
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(b))), &trip); err != nil {
		t.Fatal(err)
	}
	if !trip.Pickup.Equal(time.Date(2024, 1, 1, 14, 0, 0, 0, time.UTC)) {
		t.Fatalf("TLC local wall time interpreted as UTC: %v", trip.Pickup)
	}
}

func TestChecksumsAndSnapshotIntegrity(t *testing.T) {
	c := fixtureConfig(t, 1)
	c.SHA256File = filepath.Join(t.TempDir(), "hash.txt")
	os.WriteFile(c.SHA256File, []byte("bad-hash"), 0600)
	s := &files.Store{Root: c.Output}
	if _, err := Run(context.Background(), c, s); err == nil {
		t.Fatal("bad source checksum accepted")
	}
	s.Close(context.Background())
	c.SHA256File = ""
	r := execute(t, c)
	os.WriteFile(filepath.FromSlash(r.Manifest.Snapshot.Path), []byte("tampered"), 0600)
	s = &files.Store{Root: c.Output}
	if _, err := Run(context.Background(), c, s); err == nil {
		t.Fatal("bad snapshot checksum accepted")
	}
	s.Close(context.Background())
}

func TestDSTWallTimes(t *testing.T) {
	loc, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{"2024-03-10 02:30:00", "2024-11-03 01:30:00"} {
		if _, err := parseWall(s, loc); err == nil {
			t.Fatalf("ambiguous/nonexistent wall time accepted: %s", s)
		}
	}
	if _, err := parseWall("2024-11-03T01:30:00-04:00", loc); err != nil {
		t.Fatal("explicit offset should disambiguate:", err)
	}
}
