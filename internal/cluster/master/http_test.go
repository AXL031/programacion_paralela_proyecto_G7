package master

import (
	"context"
	"net/http/httptest"
	"testing"
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
