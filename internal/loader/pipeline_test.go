package loader

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
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
func execute(t *testing.T, c config.Loader) Result {
	t.Helper()
	s := &files.Store{Root: c.Output}
	r, err := Run(context.Background(), c, s)
	closeErr := s.Close(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if closeErr != nil {
		t.Fatal(closeErr)
	}
	return r
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
