package loader

import (
	"fmt"
	"github.com/proyecto-g7/transporte/internal/domain"
	"math"
	"time"
)

func parseWall(s string, loc *time.Location) (time.Time, error) {
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t, nil
	}
	layout := "2006-01-02 15:04:05.999999999"
	t, err := time.ParseInLocation(layout, s, loc)
	if err != nil {
		return t, err
	}
	// Detect nonexistent spring-forward wall time.
	wall, err := time.Parse(layout, s)
	if err != nil {
		return t, err
	}
	if t.In(loc).Format(layout) != wall.Format(layout) {
		return t, fmt.Errorf("nonexistent local time")
	}
	// Bare fall-back timestamps lack an offset: reject rather than choose silently.
	for _, delta := range []time.Duration{-time.Hour, time.Hour} {
		if t.Add(delta).In(loc).Format(layout) == wall.Format(layout) {
			return t, fmt.Errorf("ambiguous local time")
		}
	}
	return t, nil
}

func validate(r domain.RawTrip, loc *time.Location, start, end time.Time, zones map[int]bool, datasetID, loadID string) (domain.Trip, string) {
	if r.ParseError != "" {
		return domain.Trip{}, r.ParseError
	}
	p, err := parseWall(r.Pickup, loc)
	if err != nil {
		return domain.Trip{}, "pickup_datetime"
	}
	d, err := parseWall(r.Dropoff, loc)
	if err != nil {
		return domain.Trip{}, "dropoff_datetime"
	}
	if p.Before(start) || !p.Before(end) {
		return domain.Trip{}, "outside_period"
	}
	if !zones[r.PickupZone] || !zones[r.DropoffZone] {
		return domain.Trip{}, "unknown_zone"
	}
	if !d.After(p) {
		return domain.Trip{}, "nonpositive_duration"
	}
	if d.Sub(p) > 24*time.Hour {
		return domain.Trip{}, "duration_over_24h"
	}
	if math.IsNaN(r.Distance) || math.IsInf(r.Distance, 0) || r.Distance < 0 {
		return domain.Trip{}, "invalid_distance"
	}
	return domain.Trip{ID: fmt.Sprintf("%s:%d", loadID, r.Ordinal), DatasetID: datasetID, LoadID: loadID, SourceRow: r.Ordinal, Pickup: p.UTC(), Dropoff: d.UTC(), PickupZone: r.PickupZone, DropoffZone: r.DropoffZone, DurationSeconds: int64(d.Sub(p).Seconds()), DistanceMiles: r.Distance}, ""
}
