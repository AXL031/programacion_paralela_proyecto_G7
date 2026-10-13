package api

import (
	"context"
	"errors"
	"github.com/proyecto-g7/transporte/internal/domain"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

type fakeData struct {
	manifest    *domain.Manifest
	unavailable bool
	calls       int
}

func (d *fakeData) Ping(context.Context) error {
	if d.unavailable {
		return errors.New("offline")
	}
	return nil
}
func (d *fakeData) Current(context.Context) (*domain.Manifest, error) { return d.manifest, nil }
func (d *fakeData) Observations(context.Context, string, int, time.Time, time.Time) ([]domain.Window, error) {
	d.calls++
	return []domain.Window{}, nil
}

func TestHealthAndUnavailableData(t *testing.T) {
	d := &fakeData{unavailable: true}
	h := New(d, func(context.Context) error { return nil })
	for path, want := range map[string]int{"/health/live": 200, "/health/ready": 503, "/api/v1/datasets/current": 404} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != want {
			t.Fatalf("%s: %d", path, w.Code)
		}
	}
}
func TestInvalidObservationDoesNotReadStorage(t *testing.T) {
	d := &fakeData{}
	h := New(d, func(context.Context) error { return nil })
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/observations?zone_id=161&start=2024-01-01T00:00:00Z&end=2024-01-03T00:00:00Z", nil))
	if w.Code != http.StatusBadRequest || d.calls != 0 {
		t.Fatal("unbounded query reached storage")
	}
}
