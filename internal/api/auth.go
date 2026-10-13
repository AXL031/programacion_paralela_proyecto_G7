package api

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

const sessionCookie = "pulso_session"

type identityKey struct{}
type Claims struct {
	Role string `json:"role"`
	jwt.RegisteredClaims
}
type attempt struct {
	count int
	until time.Time
}
type Auth struct {
	key          []byte
	user         string
	passwordHash []byte
	origin       string
	secure       bool
	mu           sync.Mutex
	sessions     map[string]time.Time
	attempts     map[string]attempt
	now          func() time.Time
}

func NewAuth(key, user, password, origin string, secure bool) (*Auth, error) {
	parsed, parseErr := url.Parse(origin)
	validOrigin := parseErr == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != "" && parsed.User == nil && parsed.RawQuery == "" && parsed.Fragment == "" && (parsed.Path == "" || parsed.Path == "/")
	if len(key) < 32 || user == "" || len(password) < 12 || !validOrigin {
		return nil, fmt.Errorf("JWT_SECRET (32+ chars), DEMO_USER, DEMO_PASSWORD (12+ chars) and WEB_ORIGIN required")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}
	return &Auth{key: []byte(key), user: user, passwordHash: hash, origin: strings.TrimRight(origin, "/"), secure: secure, sessions: map[string]time.Time{}, attempts: map[string]attempt{}, now: time.Now}, nil
}
func (a *Auth) issue() (string, *Claims, error) {
	var id [24]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", nil, err
	}
	now := a.now()
	expiry := now.Add(30 * time.Minute)
	c := &Claims{Role: "operator", RegisteredClaims: jwt.RegisteredClaims{Issuer: "pulso-api", Subject: a.user, Audience: jwt.ClaimStrings{"pulso-web"}, ID: hex.EncodeToString(id[:]), IssuedAt: jwt.NewNumericDate(now), NotBefore: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(expiry)}}
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(a.key)
	if err != nil {
		return "", nil, err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for id, until := range a.sessions {
		if !until.After(now) {
			delete(a.sessions, id)
		}
	}
	if len(a.sessions) >= 128 {
		return "", nil, fmt.Errorf("session limit reached")
	}
	a.sessions[c.ID] = expiry
	return token, c, nil
}
func (a *Auth) active(c *Claims) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	expiry, ok := a.sessions[c.ID]
	return ok && expiry.After(a.now()) && c.ExpiresAt.Time.After(a.now())
}
func (a *Auth) verify(raw string) (*Claims, error) {
	if len(raw) > 8192 {
		return nil, fmt.Errorf("invalid session")
	}
	c := &Claims{}
	token, err := jwt.ParseWithClaims(raw, c, func(t *jwt.Token) (any, error) { return a.key, nil }, jwt.WithValidMethods([]string{"HS256"}), jwt.WithIssuer("pulso-api"), jwt.WithAudience("pulso-web"), jwt.WithExpirationRequired(), jwt.WithIssuedAt(), jwt.WithTimeFunc(a.now))
	if err != nil || token == nil || !token.Valid || c.Subject != a.user || c.Role != "operator" || c.ID == "" || !a.active(c) {
		return nil, fmt.Errorf("invalid session")
	}
	return c, nil
}
func (a *Auth) allowLogin(r *http.Request) bool {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if host == "" {
		host = r.RemoteAddr
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	for ip, v := range a.attempts {
		if !v.until.After(now) {
			delete(a.attempts, ip)
		}
	}
	v := a.attempts[host]
	if v.until.IsZero() {
		v.until = now.Add(time.Minute)
	}
	if v.count >= 10 || len(a.attempts) >= 2048 {
		return false
	}
	v.count++
	a.attempts[host] = v
	return true
}
func (a *Auth) routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/auth/login", func(w http.ResponseWriter, r *http.Request) {
		if origin := r.Header.Get("Origin"); origin != "" && origin != a.origin {
			send(w, 403, map[string]string{"error": "Origen no permitido."})
			return
		}
		if !a.allowLogin(r) {
			w.Header().Set("Retry-After", "60")
			send(w, 429, map[string]string{"error": "Demasiados intentos. Espera un minuto."})
			return
		}
		var input struct {
			User     string `json:"username"`
			Password string `json:"password"`
		}
		if decode(w, r, &input) != nil {
			send(w, 400, map[string]string{"error": "Usuario y contraseña requeridos."})
			return
		}
		passwordOK := bcrypt.CompareHashAndPassword(a.passwordHash, []byte(input.Password)) == nil
		userOK := subtle.ConstantTimeCompare([]byte(input.User), []byte(a.user)) == 1
		if !passwordOK || !userOK {
			send(w, 401, map[string]string{"error": "Usuario o contraseña incorrectos."})
			return
		}
		token, claims, err := a.issue()
		if err != nil {
			send(w, 503, map[string]string{"error": "No se pudo iniciar la sesión."})
			return
		}
		http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: token, Path: "/api/", HttpOnly: true, Secure: a.secure, SameSite: http.SameSiteStrictMode, MaxAge: 1800})
		send(w, 200, map[string]any{"username": a.user, "role": claims.Role, "access_token": token, "token_type": "Bearer", "expires_at": claims.ExpiresAt.Time})
	})
	mux.HandleFunc("GET /api/v1/auth/session", func(w http.ResponseWriter, r *http.Request) {
		c := r.Context().Value(identityKey{}).(*Claims)
		send(w, 200, map[string]any{"username": c.Subject, "role": c.Role, "expires_at": c.ExpiresAt.Time})
	})
	mux.HandleFunc("POST /api/v1/auth/logout", func(w http.ResponseWriter, r *http.Request) {
		c := r.Context().Value(identityKey{}).(*Claims)
		a.mu.Lock()
		delete(a.sessions, c.ID)
		a.mu.Unlock()
		http.SetCookie(w, &http.Cookie{Name: sessionCookie, Path: "/api/", HttpOnly: true, Secure: a.secure, SameSite: http.SameSiteStrictMode, MaxAge: -1})
		send(w, 200, map[string]bool{"logged_out": true})
	})
}
func (a *Auth) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/health/") || r.URL.Path == "/api/v1/auth/login" {
			next.ServeHTTP(w, r)
			return
		}
		raw := ""
		bearer := false
		if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
			raw = strings.TrimPrefix(h, "Bearer ")
			bearer = true
		} else if c, err := r.Cookie(sessionCookie); err == nil {
			raw = c.Value
		}
		claims, err := a.verify(raw)
		if err != nil {
			send(w, 401, map[string]string{"error": "Inicia sesión para acceder al proyecto."})
			return
		}
		if !bearer && r.Method != "GET" && r.Method != "HEAD" && r.Header.Get("Origin") != a.origin {
			send(w, 403, map[string]string{"error": "Origen no permitido."})
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), identityKey{}, claims)))
	})
}
