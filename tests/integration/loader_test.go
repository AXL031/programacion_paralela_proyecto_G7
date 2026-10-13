package integration

import (
	"context"
	"github.com/proyecto-g7/transporte/internal/config"
	"github.com/proyecto-g7/transporte/internal/loader"
	mongostore "github.com/proyecto-g7/transporte/internal/storage/mongo"
	"go.mongodb.org/mongo-driver/v2/bson"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestMongoLoadAndReload(t *testing.T) {
	uri := os.Getenv("MONGO_TEST_URI")
	if uri == "" {
		t.Skip("set MONGO_TEST_URI to run MongoDB integration")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// Dedicated per-test database; cleanup never touches the demo database.
	db := "transporte_test_" + time.Now().Format("20060102150405")
	s, err := mongostore.New(ctx, uri, db)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close(context.Background())
	defer s.DB.Drop(context.Background())
	c := config.Loader{Name: "integration-fixture", Source: "synthetic fixture", Input: filepath.Join("..", "testdata", "trips.csv"), Format: "csv", ZoneCatalog: filepath.Join("..", "testdata", "zones.csv"), Timezone: "America/New_York", PeriodStart: "2024-01-01T00:00:00-05:00", PeriodEnd: "2024-01-02T00:00:00-05:00", WindowMinutes: 15, Workers: 4, BlockRows: 2, BatchRows: 2, Storage: "mongo", Output: t.TempDir(), MongoURI: uri, MongoDatabase: db}
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
	trips, err := s.DB.Collection("trips").CountDocuments(ctx, bson.M{})
	if err != nil || trips != 3 {
		t.Fatalf("trip duplication: %d %v", trips, err)
	}
	windows, err := s.DB.Collection("windows").CountDocuments(ctx, bson.M{})
	if err != nil || windows != 192 {
		t.Fatalf("window duplication: %d %v", windows, err)
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
