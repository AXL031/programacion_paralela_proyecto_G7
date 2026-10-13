package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/golang-jwt/jwt/v5"
)

func testAuth(t *testing.T) *Auth {
	t.Helper()
	a, err := NewAuth(strings.Repeat("s", 40), "demo", "test-password-123", "http://localhost", false)
	if err != nil {
		t.Fatal(err)
	}
	return a
}
func TestJWTStrictValidation(t *testing.T) {
	a := testAuth(t)
	now := time.Now().Truncate(time.Second)
	a.now = func() time.Time { return now }
	raw, claims, err := a.issue()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.verify(raw); err != nil {
		t.Fatal(err)
	}
	for name, mutate := range map[string]func(*Claims){
		"issuer": func(c *Claims) { c.Issuer = "other" }, "audience": func(c *Claims) { c.Audience = jwt.ClaimStrings{"other"} }, "expired": func(c *Claims) { c.ExpiresAt = jwt.NewNumericDate(now.Add(-time.Second)) }, "missing_exp": func(c *Claims) { c.ExpiresAt = nil }, "role": func(c *Claims) { c.Role = "admin" }, "future": func(c *Claims) { c.NotBefore = jwt.NewNumericDate(now.Add(time.Hour)) },
	} {
		t.Run(name, func(t *testing.T) {
			c := *claims
			mutate(&c)
			signed, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, &c).SignedString(a.key)
			if _, err := a.verify(signed); err == nil {
				t.Fatal("invalid claims accepted")
			}
		})
	}
	otherAlgorithm, _ := jwt.NewWithClaims(jwt.SigningMethodHS384, claims).SignedString(a.key)
	if _, err := a.verify(otherAlgorithm); err == nil {
		t.Fatal("algorithm substitution accepted")
	}
	if _, err := a.verify(raw + "x"); err == nil {
		t.Fatal("tampered signature accepted")
	}
	a.mu.Lock()
	delete(a.sessions, claims.ID)
	a.mu.Unlock()
	if _, err := a.verify(raw); err == nil {
		t.Fatal("revoked session accepted")
	}
}
func TestLoginProtectionAndLogout(t *testing.T) {
	runtime, store, _, _ := predictionFixture(t)
	a := testAuth(t)
	handler := New(store, func(context.Context) error { return nil }, Options{Runtime: runtime, Auth: a})
	call := func(method, path, body, token, origin string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Origin", origin)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, req)
		return out
	}
	if w := call("GET", "/api/v1/datasets/current", "", "", ""); w.Code != 401 {
		t.Fatal("anonymous data allowed")
	}
	if w := call("POST", "/api/v1/auth/login", `{"username":"demo","password":"wrong"}`, "", ""); w.Code != 401 {
		t.Fatal("bad credentials accepted")
	}
	if w := call("POST", "/api/v1/auth/login", `{"username":"demo","password":"test-password-123"}`, "", "https://evil.example"); w.Code != 403 {
		t.Fatal("foreign login origin accepted")
	}
	login := call("POST", "/api/v1/auth/login", `{"username":"demo","password":"test-password-123"}`, "", "http://localhost")
	if login.Code != 200 {
		t.Fatal(login.Body.String())
	}
	var result struct {
		Token string `json:"access_token"`
	}
	json.Unmarshal(login.Body.Bytes(), &result)
	cookie := login.Result().Cookies()[0]
	if !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != "/api/" {
		t.Fatal("unsafe cookie")
	}
	if w := call("GET", "/api/v1/datasets/current", "", result.Token, ""); w.Code != 200 {
		t.Fatal("valid session rejected")
	}
	req := httptest.NewRequest("POST", "/api/v1/auth/logout", strings.NewReader(`{}`))
	req.AddCookie(cookie)
	req.Header.Set("Origin", "https://evil.example")
	out := httptest.NewRecorder()
	handler.ServeHTTP(out, req)
	if out.Code != 403 {
		t.Fatal("cookie CSRF accepted")
	}
	if w := call("POST", "/api/v1/auth/logout", `{}`, result.Token, ""); w.Code != 200 {
		t.Fatal("logout failed")
	}
	if w := call("GET", "/api/v1/auth/session", "", result.Token, ""); w.Code != 401 {
		t.Fatal("logout did not revoke")
	}
	for i := 0; i < 10; i++ {
		call("POST", "/api/v1/auth/login", `{"username":"demo","password":"wrong"}`, "", "")
	}
	if w := call("POST", "/api/v1/auth/login", `{"username":"demo","password":"wrong"}`, "", ""); w.Code != 429 {
		t.Fatal("login not throttled")
	}
}
func TestAuthenticatedStreamPredictionAndRevocation(t *testing.T) {
	runtime, store, _, input := predictionFixture(t)
	a := testAuth(t)
	master := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer internal-secret" {
			w.WriteHeader(401)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"workers":[],"active_run":""}`))
	}))
	defer master.Close()
	handler := New(store, func(context.Context) error { return nil }, Options{Runtime: runtime, Auth: a, MasterURL: master.URL, MasterToken: "internal-secret"})
	server := httptest.NewServer(handler)
	defer server.Close()
	a.origin = server.URL
	token, claims, err := a.issue()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 7*time.Second)
	defer cancel()
	url := strings.Replace(server.URL, "http:", "ws:", 1) + "/api/v1/events"
	headers := http.Header{"Origin": {server.URL}}
	if conn, res, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: headers}); err == nil {
		conn.CloseNow()
		t.Fatal("anonymous websocket accepted")
	} else if res == nil || res.StatusCode != 401 {
		t.Fatal("incorrect auth rejection")
	}
	headers.Set("Authorization", "Bearer "+token)
	headers.Set("Origin", "https://evil.example")
	if conn, res, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: headers}); err == nil {
		conn.CloseNow()
		t.Fatal("foreign websocket origin accepted")
	} else if res == nil || res.StatusCode != 403 {
		t.Fatal("incorrect origin rejection")
	}
	headers.Set("Origin", server.URL)
	conn, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: headers})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	var event struct {
		Type       string     `json:"type"`
		Prediction Prediction `json:"prediction"`
		ID         string     `json:"request_id"`
	}
	if err := wsjson.Read(ctx, conn, &event); err != nil || event.Type != "snapshot" {
		t.Fatalf("snapshot: %v %+v", err, event)
	}
	if err := wsjson.Write(ctx, conn, streamRequest{Type: "predict", ID: "request-1", Request: input}); err != nil {
		t.Fatal(err)
	}
	for {
		if err := wsjson.Read(ctx, conn, &event); err != nil {
			t.Fatal(err)
		}
		if event.Type == "prediction" {
			break
		}
	}
	if event.ID != "request-1" || event.Prediction.Previous != 7 || event.Prediction.Actual != 50 || event.Prediction.Version != "run-test" {
		t.Fatal("incorrect streamed prediction")
	}
	a.mu.Lock()
	delete(a.sessions, claims.ID)
	a.mu.Unlock()
	if err := wsjson.Write(ctx, conn, streamRequest{Type: "predict", ID: "after-logout", Request: input}); err != nil {
		t.Fatal(err)
	}
	for {
		err := wsjson.Read(ctx, conn, &event)
		if err != nil {
			if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
				t.Fatal("revocation did not close stream", err)
			}
			break
		}
	}
}
