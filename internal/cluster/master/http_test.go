package master

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/proyecto-g7/transporte/internal/training"
)

func TestMasterControlRequiresInternalToken(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server := New(ctx, nil)
	server.Secret = "test-internal-token"
	for _, tc := range []struct {
		path, token string
		status      int
	}{
		{"/health/live", "", 200}, {"/cluster", "", 401}, {"/cluster", "wrong", 401}, {"/cluster", "test-internal-token", 200},
	} {
		req := httptest.NewRequest("GET", tc.path, nil)
		if tc.token != "" {
			req.Header.Set("Authorization", "Bearer "+tc.token)
		}
		res := httptest.NewRecorder()
		server.Handler().ServeHTTP(res, req)
		if res.Code != tc.status {
			t.Fatalf("%s %d", tc.path, res.Code)
		}
	}
}

func TestCandidateEndpointRequiresTokenAndReturnsPreSelectionWeights(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server := New(ctx, nil)
	server.Secret = "test-internal-token"
	server.candidates["run-1"] = training.Candidate{RunID: "run-1", Mode: "distributed", Dimension: 2, Weights: []float64{1, 2}}

	req := httptest.NewRequest("GET", "/runs/run-1/candidate", nil)
	res := httptest.NewRecorder()
	server.Handler().ServeHTTP(res, req)
	if res.Code != 401 {
		t.Fatalf("candidate endpoint without token: %d", res.Code)
	}

	for path, want := range map[string]int{"/runs/missing/candidate": 404, "/runs/run-1/candidate": 200} {
		req := httptest.NewRequest("GET", path, nil)
		req.Header.Set("Authorization", "Bearer test-internal-token")
		res := httptest.NewRecorder()
		server.Handler().ServeHTTP(res, req)
		if res.Code != want {
			t.Fatalf("%s: %d, want %d", path, res.Code, want)
		}
		if want == 200 {
			var candidate training.Candidate
			if err := json.NewDecoder(res.Body).Decode(&candidate); err != nil {
				t.Fatal(err)
			}
			if candidate.RunID != "run-1" || len(candidate.Weights) != 2 {
				t.Fatalf("unexpected candidate: %+v", candidate)
			}
		}
	}
}
