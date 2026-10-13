package mongo

import (
	"context"
	"errors"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/domain"
	"go.mongodb.org/mongo-driver/v2/bson"
	driver "go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"time"
)

type Store struct {
	Client *driver.Client
	DB     *driver.Database
}

func New(ctx context.Context, uri, db string) (*Store, error) {
	c, err := driver.Connect(options.Client().ApplyURI(uri).SetServerSelectionTimeout(5 * time.Second).SetTimeout(30 * time.Second))
	if err != nil {
		return nil, err
	}
	if err := c.Ping(ctx, nil); err != nil {
		c.Disconnect(context.Background())
		return nil, fmt.Errorf("MongoDB unavailable: %w", err)
	}
	return &Store{Client: c, DB: c.Database(db)}, nil
}
func (s *Store) Ping(ctx context.Context) error  { return s.Client.Ping(ctx, nil) }
func (s *Store) Close(ctx context.Context) error { return s.Client.Disconnect(ctx) }

func (s *Store) FindComplete(ctx context.Context, id string) (*domain.Manifest, error) {
	var m domain.Manifest
	err := s.DB.Collection("datasets").FindOne(ctx, bson.M{"_id": id, "status": "complete"}).Decode(&m)
	if errors.Is(err, driver.ErrNoDocuments) {
		return nil, nil
	}
	return &m, err
}
func (s *Store) Begin(ctx context.Context, m domain.Manifest) error {
	_, err := s.DB.Collection("datasets").InsertOne(ctx, m)
	if driver.IsDuplicateKeyError(err) {
		// Only a recorded failure can be retried; never take a live owner's lock.
		res, e := s.DB.Collection("datasets").ReplaceOne(ctx, bson.M{"_id": m.ID, "status": "failed"}, m)
		if e != nil {
			return e
		}
		if res.MatchedCount == 0 {
			return fmt.Errorf("dataset already loading or published; no concurrent overwrite")
		}
		err = nil
	}
	if err != nil {
		return err
	}
	for _, spec := range []struct {
		collection string
		keys       bson.D
	}{
		{"trips", bson.D{{Key: "load_id", Value: 1}, {Key: "source_row", Value: 1}}},
		{"windows", bson.D{{Key: "load_id", Value: 1}, {Key: "start", Value: 1}, {Key: "zone_id", Value: 1}}},
	} {
		if _, err := s.DB.Collection(spec.collection).Indexes().CreateOne(ctx, driver.IndexModel{Keys: spec.keys, Options: options.Index().SetUnique(true)}); err != nil {
			m.Status = "failed"
			m.Error = err.Error()
			s.Fail(ctx, m)
			return err
		}
	}
	return nil
}
func (s *Store) WriteTrips(ctx context.Context, trips []domain.Trip) error {
	docs := make([]any, len(trips))
	for i := range trips {
		docs[i] = trips[i]
	}
	_, err := s.DB.Collection("trips").InsertMany(ctx, docs, options.InsertMany().SetOrdered(false))
	return err
}
func (s *Store) WriteWindows(ctx context.Context, windows []domain.Window) error {
	docs := make([]any, len(windows))
	for i := range windows {
		docs[i] = windows[i]
	}
	_, err := s.DB.Collection("windows").InsertMany(ctx, docs, options.InsertMany().SetOrdered(false))
	return err
}
func (s *Store) Complete(ctx context.Context, m domain.Manifest) error {
	res, err := s.DB.Collection("datasets").ReplaceOne(ctx, bson.M{"_id": m.ID, "load_id": m.LoadID, "status": bson.M{"$in": bson.A{"loading", "complete"}}}, m)
	if err != nil {
		return err
	}
	if res.MatchedCount != 1 {
		return fmt.Errorf("load ownership lost")
	}
	_, err = s.DB.Collection("settings").UpdateOne(ctx, bson.M{"_id": "current_dataset"}, bson.M{"$set": bson.M{"dataset_id": m.ID}}, options.UpdateOne().SetUpsert(true))
	return err
}
func (s *Store) Fail(ctx context.Context, m domain.Manifest) error {
	_, err := s.DB.Collection("datasets").ReplaceOne(ctx, bson.M{"_id": m.ID, "load_id": m.LoadID, "status": "loading"}, m)
	return err
}
func (s *Store) Current(ctx context.Context) (*domain.Manifest, error) {
	var p struct {
		ID string `bson:"dataset_id"`
	}
	err := s.DB.Collection("settings").FindOne(ctx, bson.M{"_id": "current_dataset"}).Decode(&p)
	if err != nil {
		return nil, err
	}
	return s.FindComplete(ctx, p.ID)
}

func (s *Store) Observations(ctx context.Context, loadID string, zone int, start, end time.Time) ([]domain.Window, error) {
	cursor, err := s.DB.Collection("windows").Find(ctx, bson.M{"load_id": loadID, "zone_id": zone, "start": bson.M{"$gte": start, "$lt": end}}, options.Find().SetSort(bson.D{{Key: "start", Value: 1}}).SetLimit(1440))
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx)
	rows := []domain.Window{}
	if err := cursor.All(ctx, &rows); err != nil {
		return nil, err
	}
	return rows, nil
}

func (s *Store) Windows(ctx context.Context, loadID string) ([]domain.Window, error) {
	cursor, err := s.DB.Collection("windows").Find(ctx, bson.M{"load_id": loadID}, options.Find().SetLimit(2000001))
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx)
	var rows []domain.Window
	if err := cursor.All(ctx, &rows); err != nil {
		return nil, err
	}
	if len(rows) > 2000000 {
		return nil, fmt.Errorf("window limit exceeded")
	}
	return rows, nil
}
