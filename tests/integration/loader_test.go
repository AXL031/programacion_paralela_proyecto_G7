package integration

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"sync/atomic"
	"testing"
	"time"

	"github.com/proyecto-g7/transporte/internal/config"
	"github.com/proyecto-g7/transporte/internal/domain"
	"github.com/proyecto-g7/transporte/internal/loader"
	mongostore "github.com/proyecto-g7/transporte/internal/storage/mongo"
	"go.mongodb.org/mongo-driver/v2/bson"
)

var mongoTestSequence int64

func mongoTestURI(t *testing.T) string {
	t.Helper()
	uri := os.Getenv("MONGO_TEST_URI")
	if uri == "" {
		t.Skip("set MONGO_TEST_URI to run MongoDB integration")
	}
	return uri
}

// newMongoTestStore creates an isolated database per trial. Cleanup only drops
// that database, never the demo database or the fixed benchmark database.
func newMongoTestStore(t *testing.T, ctx context.Context, uri string) (*mongostore.Store, string) {
	t.Helper()
	db := fmt.Sprintf("transporte_test_%d_%d", time.Now().UnixNano(), atomic.AddInt64(&mongoTestSequence, 1))
	s, err := mongostore.New(ctx, uri, db)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := s.DB.Drop(cleanup); err != nil {
			t.Errorf("drop test database %s: %v", db, err)
		}
		if err := s.Close(cleanup); err != nil {
			t.Errorf("close test client %s: %v", db, err)
		}
	})
	return s, db
}

func mongoLoaderConfig(t *testing.T, workers int, uri, db string) config.Loader {
	t.Helper()
	return config.Loader{
		Name:          "integration-fixture",
		Source:        "synthetic fixture",
		Input:         filepath.Join("..", "testdata", "trips.csv"),
		Format:        "csv",
		ZoneCatalog:   filepath.Join("..", "testdata", "zones.csv"),
		Timezone:      "America/New_York",
		PeriodStart:   "2024-01-01T00:00:00-05:00",
		PeriodEnd:     "2024-01-02T00:00:00-05:00",
		WindowMinutes: 15,
		Workers:       workers,
		BlockRows:     2,
		BatchRows:     2,
		Storage:       "mongo",
		Output:        t.TempDir(),
		MongoURI:      uri,
		MongoDatabase: db,
	}
}

func readMongoTrips(t *testing.T, ctx context.Context, s *mongostore.Store) []domain.Trip {
	t.Helper()
	cursor, err := s.DB.Collection("trips").Find(ctx, bson.M{})
	if err != nil {
		t.Fatal(err)
	}
	defer cursor.Close(ctx)
	var trips []domain.Trip
	if err := cursor.All(ctx, &trips); err != nil {
		t.Fatal(err)
	}
	sort.Slice(trips, func(i, j int) bool { return trips[i].SourceRow < trips[j].SourceRow })
	return trips
}

func readMongoWindows(t *testing.T, ctx context.Context, s *mongostore.Store, loadID string) []domain.Window {
	t.Helper()
	windows, err := s.Windows(ctx, loadID)
	if err != nil {
		t.Fatal(err)
	}
	sort.Slice(windows, func(i, j int) bool {
		if windows[i].Start.Equal(windows[j].Start) {
			return windows[i].ZoneID < windows[j].ZoneID
		}
		return windows[i].Start.Before(windows[j].Start)
	})
	return windows
}

func countMongo(t *testing.T, ctx context.Context, s *mongostore.Store, collection string, filter bson.M) int64 {
	t.Helper()
	count, err := s.DB.Collection(collection).CountDocuments(ctx, filter)
	if err != nil {
		t.Fatalf("count %s: %v", collection, err)
	}
	return count
}

func normalizedMongoTrips(trips []domain.Trip) []domain.Trip {
	out := append([]domain.Trip(nil), trips...)
	for i := range out {
		out[i].ID = ""
		out[i].LoadID = ""
	}
	return out
}

func normalizedMongoWindows(windows []domain.Window) []domain.Window {
	out := append([]domain.Window(nil), windows...)
	for i := range out {
		out[i].ID = ""
		out[i].LoadID = ""
	}
	return out
}

func TestMongoLoadAndReload(t *testing.T) {
	uri := mongoTestURI(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	s, db := newMongoTestStore(t, ctx, uri)
	c := mongoLoaderConfig(t, 4, uri, db)

	a, err := loader.Run(ctx, c, s)
	if err != nil {
		t.Fatal(err)
	}
	b, err := loader.Run(ctx, c, s)
	if err != nil {
		t.Fatal(err)
	}
	if !b.Reused || a.Manifest.LoadID != b.Manifest.LoadID {
		t.Fatal("reload did not reuse successful load")
	}
	trips := countMongo(t, ctx, s, "trips", bson.M{})
	if trips != 3 {
		t.Fatalf("trip duplication: %d", trips)
	}
	windows := countMongo(t, ctx, s, "windows", bson.M{})
	if windows != 192 {
		t.Fatalf("window duplication: %d", windows)
	}
	current, err := s.Current(ctx)
	if err != nil || current == nil || current.ID != a.Manifest.ID {
		t.Fatalf("current dataset publication: %v", err)
	}
	rows, err := s.Observations(ctx, current.LoadID, 161, current.Start, current.End)
	if err != nil || len(rows) != 96 {
		t.Fatalf("observations: %d %v", len(rows), err)
	}
	var sum int64
	for _, r := range rows {
		sum += r.Count
	}
	if sum != 2 {
		t.Fatalf("wrong zone count: %d", sum)
	}
}

func TestMongoStrictReuseRejection(t *testing.T) {
	uri := mongoTestURI(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	s, db := newMongoTestStore(t, ctx, uri)
	c := mongoLoaderConfig(t, 1, uri, db)

	first, err := loader.Run(ctx, c, s)
	if err != nil {
		t.Fatal(err)
	}
	tripsBefore := countMongo(t, ctx, s, "trips", bson.M{})
	windowsBefore := countMongo(t, ctx, s, "windows", bson.M{})

	rejected, err := loader.RunWithOptions(ctx, c, s, loader.RunOptions{RejectReuse: true})
	if !errors.Is(err, loader.ErrReuseRejected) {
		t.Fatalf("expected ErrReuseRejected, got %v", err)
	}
	if rejected.Reused || rejected.Manifest.ID != "" || rejected.Manifest.Stats.Accepted != 0 {
		t.Fatalf("strict rejection returned historical metrics: %+v", rejected)
	}
	if rejected.Configuration.Workers != 1 {
		t.Fatalf("strict rejection lost configuration: %+v", rejected.Configuration)
	}

	stored, err := s.FindComplete(ctx, first.Manifest.ID)
	if err != nil || stored == nil {
		t.Fatalf("published load was lost: %v", err)
	}
	if stored.Status != "complete" || stored.LoadID != first.Manifest.LoadID {
		t.Fatalf("strict rejection changed the published load: %+v", stored)
	}
	if got := countMongo(t, ctx, s, "trips", bson.M{}); got != tripsBefore {
		t.Fatalf("strict rejection changed trips: %d != %d", got, tripsBefore)
	}
	if got := countMongo(t, ctx, s, "windows", bson.M{}); got != windowsBefore {
		t.Fatalf("strict rejection changed windows: %d != %d", got, windowsBefore)
	}
	current, err := s.Current(ctx)
	if err != nil || current == nil || current.LoadID != first.Manifest.LoadID {
		t.Fatalf("strict rejection changed the current dataset: %v", err)
	}
}

func TestMongoL1L4LogicalEquivalence(t *testing.T) {
	uri := mongoTestURI(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	l1Store, l1DB := newMongoTestStore(t, ctx, uri)
	l4Store, l4DB := newMongoTestStore(t, ctx, uri)
	l1Config := mongoLoaderConfig(t, 1, uri, l1DB)
	l4Config := mongoLoaderConfig(t, 4, uri, l4DB)

	l1, err := loader.Run(ctx, l1Config, l1Store)
	if err != nil {
		t.Fatalf("L1 load: %v", err)
	}
	l4, err := loader.Run(ctx, l4Config, l4Store)
	if err != nil {
		t.Fatalf("L4 load: %v", err)
	}
	if l1.Reused || l4.Reused {
		t.Fatal("fresh database unexpectedly reused a load")
	}
	if l1.Manifest.ID != l4.Manifest.ID {
		t.Fatalf("worker count changed dataset identity: %s != %s", l1.Manifest.ID, l4.Manifest.ID)
	}

	fields := map[string][2]string{
		"name":               {l1.Manifest.Name, l4.Manifest.Name},
		"source":             {l1.Manifest.Source, l4.Manifest.Source},
		"source_url":         {l1.Manifest.SourceURL, l4.Manifest.SourceURL},
		"source_sha256":      {l1.Manifest.SourceSHA256, l4.Manifest.SourceSHA256},
		"catalog_sha256":     {l1.Manifest.CatalogSHA256, l4.Manifest.CatalogSHA256},
		"format":             {l1.Manifest.Format, l4.Manifest.Format},
		"timezone":           {l1.Manifest.Timezone, l4.Manifest.Timezone},
		"processing_version": {l1.Manifest.ProcessingVersion, l4.Manifest.ProcessingVersion},
		"status":             {l1.Manifest.Status, l4.Manifest.Status},
	}
	for name, pair := range fields {
		if pair[0] != pair[1] {
			t.Fatalf("%s changed with worker count: %q != %q", name, pair[0], pair[1])
		}
	}
	if l1.Manifest.WindowMinutes != l4.Manifest.WindowMinutes || !l1.Manifest.Start.Equal(l4.Manifest.Start) || !l1.Manifest.End.Equal(l4.Manifest.End) {
		t.Fatal("period/window changed with worker count")
	}
	if !reflect.DeepEqual(l1.Manifest.Zones, l4.Manifest.Zones) {
		t.Fatal("zone catalog changed with worker count")
	}

	want := struct {
		read, accepted, rejected, outside, persisted int64
	}{read: 8, accepted: 3, rejected: 4, outside: 1, persisted: 3}
	wantRejections := map[string]int64{
		"nonpositive_duration": 1,
		"unknown_zone":         1,
		"pickup_datetime":      1,
		"invalid_distance":     1,
	}
	for _, got := range []domain.Stats{l1.Manifest.Stats, l4.Manifest.Stats} {
		if got.Read != want.read || got.Accepted != want.accepted || got.Rejected != want.rejected || got.OutsidePeriod != want.outside || got.Persisted != want.persisted {
			t.Fatalf("unexpected counts: %+v", got)
		}
		if !reflect.DeepEqual(got.Rejections, wantRejections) {
			t.Fatalf("unexpected rejection causes: %+v", got.Rejections)
		}
	}

	s1, s4 := l1.Manifest.Snapshot, l4.Manifest.Snapshot
	if s1.SHA256 != s4.SHA256 || s1.Windows != s4.Windows || s1.Examples != s4.Examples {
		t.Fatalf("snapshot identity changed with worker count: %+v != %+v", s1, s4)
	}
	if s1.Version != s4.Version || s1.Normalization != s4.Normalization || !s1.TrainEnd.Equal(s4.TrainEnd) || !s1.ValidationEnd.Equal(s4.ValidationEnd) {
		t.Fatal("snapshot metadata changed with worker count")
	}
	if !reflect.DeepEqual(s1.FeatureNames, s4.FeatureNames) || !reflect.DeepEqual(s1.Splits, s4.Splits) {
		t.Fatal("snapshot features/splits changed with worker count")
	}
	wantSplits := map[string]int64{"train": 132, "validation": 28, "test": 30}
	if !reflect.DeepEqual(s1.Splits, wantSplits) {
		t.Fatalf("unexpected splits: %+v", s1.Splits)
	}
	if s1.Windows != 192 || s1.Examples != 190 {
		t.Fatalf("unexpected snapshot size: windows=%d examples=%d", s1.Windows, s1.Examples)
	}

	features1 := filepath.FromSlash(s1.Path)
	features4 := filepath.FromSlash(s4.Path)
	if got, err := loader.FileSHA256(features1); err != nil || got != s1.SHA256 {
		t.Fatalf("snapshot checksum mismatch: %s %v", got, err)
	}
	bytes1, err := os.ReadFile(features1)
	if err != nil {
		t.Fatal(err)
	}
	bytes4, err := os.ReadFile(features4)
	if err != nil {
		t.Fatal(err)
	}
	if string(bytes1) != string(bytes4) {
		t.Fatal("feature snapshot bytes changed with worker count")
	}

	for label, pair := range map[string]struct {
		store  *mongostore.Store
		config config.Loader
		run    loader.Result
	}{
		"L1": {l1Store, l1Config, l1},
		"L4": {l4Store, l4Config, l4},
	} {
		manifest := pair.run.Manifest
		if got := countMongo(t, ctx, pair.store, "trips", bson.M{"load_id": manifest.LoadID}); got != manifest.Stats.Accepted {
			t.Fatalf("%s mongo trips %d != accepted %d", label, got, manifest.Stats.Accepted)
		}
		if got := countMongo(t, ctx, pair.store, "windows", bson.M{"load_id": manifest.LoadID}); got != manifest.Snapshot.Windows {
			t.Fatalf("%s mongo windows %d != snapshot windows %d", label, got, manifest.Snapshot.Windows)
		}
		windows := readMongoWindows(t, ctx, pair.store, manifest.LoadID)
		var sum int64
		for _, window := range windows {
			sum += window.Count
		}
		if sum != manifest.Stats.Accepted {
			t.Fatalf("%s window sum %d != accepted %d", label, sum, manifest.Stats.Accepted)
		}
	}

	trips1 := normalizedMongoTrips(readMongoTrips(t, ctx, l1Store))
	trips4 := normalizedMongoTrips(readMongoTrips(t, ctx, l4Store))
	if !reflect.DeepEqual(trips1, trips4) {
		t.Fatal("logical trips changed with worker count")
	}

	windows1 := normalizedMongoWindows(readMongoWindows(t, ctx, l1Store, l1.Manifest.LoadID))
	windows4 := normalizedMongoWindows(readMongoWindows(t, ctx, l4Store, l4.Manifest.LoadID))
	if !reflect.DeepEqual(windows1, windows4) {
		t.Fatal("logical windows changed with worker count")
	}
}
