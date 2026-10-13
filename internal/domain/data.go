package domain

import "time"

type RawTrip struct {
	Ordinal                 int64
	Pickup, Dropoff         string
	PickupZone, DropoffZone int
	Distance                float64
	ParseError              string
}

type Trip struct {
	ID              string    `json:"id" bson:"_id"`
	DatasetID       string    `json:"dataset_id" bson:"dataset_id"`
	LoadID          string    `json:"load_id" bson:"load_id"`
	SourceRow       int64     `json:"source_row" bson:"source_row"`
	Pickup          time.Time `json:"pickup" bson:"pickup"`
	Dropoff         time.Time `json:"dropoff" bson:"dropoff"`
	PickupZone      int       `json:"pickup_zone" bson:"pickup_zone"`
	DropoffZone     int       `json:"dropoff_zone" bson:"dropoff_zone"`
	DurationSeconds int64     `json:"duration_seconds" bson:"duration_seconds"`
	DistanceMiles   float64   `json:"distance_miles" bson:"distance_miles"`
}

type Zone struct {
	ID      int    `json:"id" bson:"_id"`
	Name    string `json:"name" bson:"name"`
	Borough string `json:"borough" bson:"borough"`
}

type Window struct {
	ID        string    `json:"id" bson:"_id"`
	DatasetID string    `json:"dataset_id" bson:"dataset_id"`
	LoadID    string    `json:"load_id" bson:"load_id"`
	ZoneID    int       `json:"zone_id" bson:"zone_id"`
	Start     time.Time `json:"start" bson:"start"`
	Count     int64     `json:"observed_trips" bson:"observed_trips"`
	Coverage  string    `json:"coverage" bson:"coverage"`
}

type Stats struct {
	Read           int64            `json:"read" bson:"read"`
	Accepted       int64            `json:"accepted" bson:"accepted"`
	Rejected       int64            `json:"rejected" bson:"rejected"`
	OutsidePeriod  int64            `json:"outside_period" bson:"outside_period"`
	Persisted      int64            `json:"persisted" bson:"persisted"`
	Rejections     map[string]int64 `json:"rejection_reasons" bson:"rejection_reasons"`
	ElapsedSeconds float64          `json:"elapsed_seconds" bson:"elapsed_seconds"`
	RowsPerSecond  float64          `json:"rows_per_second" bson:"rows_per_second"`
}

type Snapshot struct {
	Version       string           `json:"version" bson:"version"`
	Path          string           `json:"path" bson:"path"`
	SHA256        string           `json:"sha256" bson:"sha256"`
	Windows       int64            `json:"windows" bson:"windows"`
	Examples      int64            `json:"examples" bson:"examples"`
	Splits        map[string]int64 `json:"splits" bson:"splits"`
	FeatureNames  []string         `json:"feature_names" bson:"feature_names"`
	TrainEnd      time.Time        `json:"train_end" bson:"train_end"`
	ValidationEnd time.Time        `json:"validation_end" bson:"validation_end"`
	Normalization string           `json:"normalization" bson:"normalization"`
}

type Manifest struct {
	ID                string    `json:"dataset_id" bson:"_id"`
	Name              string    `json:"name" bson:"name"`
	LoadID            string    `json:"load_id" bson:"load_id"`
	Status            string    `json:"status" bson:"status"`
	Source            string    `json:"source" bson:"source"`
	SourceURL         string    `json:"source_url" bson:"source_url"`
	SourceSHA256      string    `json:"source_sha256" bson:"source_sha256"`
	CatalogSHA256     string    `json:"catalog_sha256" bson:"catalog_sha256"`
	Format            string    `json:"format" bson:"format"`
	Timezone          string    `json:"timezone" bson:"timezone"`
	Start             time.Time `json:"period_start" bson:"period_start"`
	End               time.Time `json:"period_end_exclusive" bson:"period_end_exclusive"`
	WindowMinutes     int       `json:"window_minutes" bson:"window_minutes"`
	ProcessingVersion string    `json:"processing_version" bson:"processing_version"`
	CreatedAt         time.Time `json:"created_at" bson:"created_at"`
	CompletedAt       time.Time `json:"completed_at,omitempty" bson:"completed_at,omitempty"`
	Stats             Stats     `json:"stats" bson:"stats"`
	Snapshot          Snapshot  `json:"snapshot" bson:"snapshot"`
	Zones             []Zone    `json:"zones" bson:"zones"`
	Error             string    `json:"error,omitempty" bson:"error,omitempty"`
}
