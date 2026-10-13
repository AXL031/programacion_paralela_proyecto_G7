package mongo

import (
	"context"
	"github.com/proyecto-g7/transporte/internal/storage/files"
	"github.com/proyecto-g7/transporte/internal/training"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"os"
	"path/filepath"
	"time"
)

func (s *Store) SaveRun(ctx context.Context, r training.Run) error {
	_, err := s.DB.Collection("training_runs").ReplaceOne(ctx, bson.M{"_id": r.ID}, r, options.Replace().SetUpsert(true))
	return err
}
func (s *Store) Publish(ctx context.Context, a training.Artifact) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := a.Validate(); err != nil {
		return err
	}
	dir := os.Getenv("MODEL_OUTPUT")
	if dir == "" {
		dir = "data/models"
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	if err := files.WriteJSON(filepath.Join(dir, a.Version+".json"), a); err != nil {
		return err
	}
	_, err := s.DB.Collection("models").InsertOne(ctx, bson.M{"_id": a.Version, "artifact": a})
	if err != nil {
		return err
	}
	_, err = s.DB.Collection("settings").UpdateOne(ctx, bson.M{"_id": "current_model"}, bson.M{"$set": bson.M{"version": a.Version}}, options.UpdateOne().SetUpsert(true))
	return err
}
func (s *Store) Model(ctx context.Context, version string) (training.Artifact, error) {
	if version == "current" {
		var pointer struct{ Version string }
		if err := s.DB.Collection("settings").FindOne(ctx, bson.M{"_id": "current_model"}).Decode(&pointer); err != nil {
			return training.Artifact{}, err
		}
		version = pointer.Version
	}
	var record struct{ Artifact training.Artifact }
	err := s.DB.Collection("models").FindOne(ctx, bson.M{"_id": version}).Decode(&record)
	if err != nil {
		return record.Artifact, err
	}
	return record.Artifact, record.Artifact.Validate()
}
func (s *Store) TrainingRun(ctx context.Context, id string) (training.Run, error) {
	var run training.Run
	err := s.DB.Collection("training_runs").FindOne(ctx, bson.M{"_id": id}).Decode(&run)
	return run, err
}

// This deployment has one master. Finalize its interrupted runs on restart.
func (s *Store) RecoverInterrupted(ctx context.Context) error {
	_, err := s.DB.Collection("training_runs").UpdateMany(ctx, bson.M{"mode": "distributed", "status": bson.M{"$in": bson.A{"queued", "preparing", "running"}}}, bson.M{"$set": bson.M{"status": "failed", "error": "El coordinador se reinició. El modelo anterior se conserva.", "completedat": time.Now().UTC()}})
	return err
}
