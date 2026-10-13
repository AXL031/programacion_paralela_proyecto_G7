package integration

import (
	"context"
	"encoding/json"
	"github.com/proyecto-g7/transporte/internal/config"
	"github.com/proyecto-g7/transporte/internal/features"
	"github.com/proyecto-g7/transporte/internal/loader"
	"github.com/proyecto-g7/transporte/internal/ml"
	mongostore "github.com/proyecto-g7/transporte/internal/storage/mongo"
	"github.com/proyecto-g7/transporte/internal/training"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestTrainingArtifactMongoAndFileRoundTrip(t *testing.T) {
	uri := os.Getenv("MONGO_TEST_URI")
	if uri == "" {
		t.Skip("set MONGO_TEST_URI for MongoDB integration")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db := "transporte_training_test_" + time.Now().Format("20060102150405")
	s, err := mongostore.New(ctx, uri, db)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close(context.Background())
	defer s.DB.Drop(context.Background())
	output := t.TempDir()
	t.Setenv("MODEL_OUTPUT", output)
	c := config.Loader{Name: "training-fixture", Source: "synthetic fixture", Input: filepath.Join("..", "testdata", "trips.csv"), Format: "csv", ZoneCatalog: filepath.Join("..", "testdata", "zones.csv"), Timezone: "America/New_York", PeriodStart: "2024-01-01T00:00:00-05:00", PeriodEnd: "2024-01-02T00:00:00-05:00", WindowMinutes: 15, Workers: 2, BlockRows: 2, BatchRows: 2, Storage: "mongo", Output: t.TempDir(), MongoURI: uri, MongoDatabase: db}
	loaded, err := loader.Run(ctx, c, s)
	if err != nil {
		t.Fatal(err)
	}
	config := ml.Config{Epochs: 3, BatchSize: 16, LearningRate: 0.04, L2: 0.0001, Seed: 42, Workers: 1, TaskTimeoutSeconds: 2}
	a, r, err := training.Sequential(ctx, loaded.Manifest, config, s)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status != "completed" {
		t.Fatal("training not complete")
	}
	mongoModel, err := s.Model(ctx, "current")
	if err != nil {
		t.Fatal(err)
	}
	record, err := s.TrainingRun(ctx, r.ID)
	if err != nil || record.Status != "completed" {
		t.Fatal("run not persisted")
	}
	b, err := os.ReadFile(filepath.Join(output, a.Version+".json"))
	if err != nil {
		t.Fatal(err)
	}
	var fileModel training.Artifact
	if err := json.Unmarshal(b, &fileModel); err != nil {
		t.Fatal(err)
	}
	if err := fileModel.Validate(); err != nil {
		t.Fatal(err)
	}
	x := features.Example{ZoneID: 161, HourSin: 0.5, HourCos: 0.8, DayOfWeek: 3, Lag1: 5}
	for _, model := range []training.Artifact{a, mongoModel, fileModel} {
		row, err := model.Encoder.Encode(x)
		if err != nil {
			t.Fatal(err)
		}
		got, err := ml.Predict(model.Weights, row)
		if err != nil {
			t.Fatal(err)
		}
		referenceRow, _ := a.Encoder.Encode(x)
		want, _ := ml.Predict(a.Weights, referenceRow)
		if got != want {
			t.Fatal("artifact reload changed prediction")
		}
	}
	bad := a
	bad.Version = training.NewID()
	bad.Weights = append([]float64(nil), a.Weights...)
	bad.Weights[0] = math.NaN()
	if err := s.Publish(ctx, bad); err == nil {
		t.Fatal("non-finite candidate published")
	}
	current, err := s.Model(ctx, "current")
	if err != nil || current.Version != a.Version {
		t.Fatal("invalid candidate replaced current model")
	}
}
