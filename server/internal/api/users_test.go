package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"

	"ipvexa/internal/notify"
	"ipvexa/internal/store"
)

type testEnv struct {
	t     *testing.T
	h     http.Handler
	db    *store.Store
	admin string // admin session token
}

func newEnv(t *testing.T) *testEnv {
	db, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	hash, _ := bcrypt.GenerateFromPassword([]byte("adminpass1"), bcrypt.MinCost)
	u := store.User{Username: "admin", Hash: string(hash), Role: "admin"}
	if err := db.CreateUser(&u); err != nil {
		t.Fatal(err)
	}
	tok, _ := db.NewSession(u.ID, time.Hour)
	return &testEnv{t: t, h: (&Server{Store: db, Notify: notify.New(db)}).Handler(), db: db, admin: tok}
}

func (e *testEnv) do(method, path, token string, body any) (int, map[string]any) {
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req := httptest.NewRequest(method, path, &buf)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

// list GETs a JSON array.
func (e *testEnv) list(path, token string) (int, []any) {
	req := httptest.NewRequest("GET", path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	var out []any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func (e *testEnv) login(user, pass string) string {
	code, out := e.do("POST", "/api/login", "", map[string]string{"username": user, "password": pass})
	if code != 200 {
		e.t.Fatalf("login %s: %d %v", user, code, out)
	}
	return out["token"].(string)
}

func TestUserLifecycle(t *testing.T) {
	e := newEnv(t)

	if code, _ := e.do("POST", "/api/users", e.admin, map[string]any{"username": "bob", "role": "viewer", "password": "short"}); code != 400 {
		t.Errorf("short password: got %d, want 400", code)
	}
	if code, _ := e.do("POST", "/api/users", e.admin, map[string]any{"username": "bad name!", "role": "viewer", "password": "longenough"}); code != 400 {
		t.Errorf("bad username: got %d, want 400", code)
	}
	code, bob := e.do("POST", "/api/users", e.admin, map[string]any{
		"username": "bob", "full_name": "Bob", "role": "viewer", "password": "bobspassword",
		"permissions": map[string]any{"all_cameras": false, "cameras": []int{7}, "playback": false, "ptz": false},
	})
	if code != 201 {
		t.Fatalf("create bob: %d %v", code, bob)
	}
	if code, _ := e.do("POST", "/api/users", e.admin, map[string]any{"username": "BOB", "role": "viewer", "password": "bobspassword"}); code != 409 {
		t.Errorf("duplicate (case-insensitive) name: got %d, want 409", code)
	}

	bt := e.login("bob", "bobspassword")
	if code, _ := e.do("GET", "/api/users", bt, nil); code != 403 {
		t.Errorf("viewer listing users: got %d, want 403", code)
	}
	if code, _ := e.do("GET", "/api/cameras/3/timeline?from=0&to=1", bt, nil); code != 404 {
		t.Errorf("camera outside the allowed list: got %d, want 404", code)
	}
	if code, _ := e.do("GET", "/api/cameras/7/timeline?from=0&to=1", bt, nil); code != 403 {
		t.Errorf("playback without permission: got %d, want 403", code)
	}
	if code, _ := e.do("POST", "/api/cameras/7/ptz/stop", bt, nil); code != 403 {
		t.Errorf("PTZ without permission: got %d, want 403", code)
	}

	// Changing your own password needs the current one and keeps this session.
	if code, _ := e.do("POST", "/api/me/password", bt, map[string]string{"current": "wrong", "new": "newbobpass"}); code != 403 {
		t.Errorf("wrong current password: got %d, want 403", code)
	}
	if code, _ := e.do("POST", "/api/me/password", bt, map[string]string{"current": "bobspassword", "new": "newbobpass"}); code != 204 {
		t.Errorf("change own password: got %d, want 204", code)
	}
	if code, _ := e.do("GET", "/api/me", bt, nil); code != 200 {
		t.Errorf("session after own password change: got %d, want 200", code)
	}
	e.login("bob", "newbobpass")

	// Disabling signs the user out and blocks logins.
	id := int(bob["id"].(float64))
	path := "/api/users/" + itoa(id)
	if code, out := e.do("PUT", path, e.admin, map[string]any{"username": "bob", "role": "viewer", "disabled": true}); code != 200 {
		t.Fatalf("disable: %d %v", code, out)
	}
	if code, _ := e.do("GET", "/api/me", bt, nil); code != 401 {
		t.Errorf("disabled user's session: got %d, want 401", code)
	}
	if code, _ := e.do("POST", "/api/login", "", map[string]string{"username": "bob", "password": "newbobpass"}); code != 403 {
		t.Errorf("disabled login: got %d, want 403", code)
	}

	if code, _ := e.do("DELETE", path, e.admin, nil); code != 204 {
		t.Errorf("delete: got %d, want 204", code)
	}
}

func TestAdminSafety(t *testing.T) {
	e := newEnv(t)
	_, me := e.do("GET", "/api/me", e.admin, nil)
	self := "/api/users/" + itoa(int(me["id"].(float64)))
	if code, _ := e.do("DELETE", self, e.admin, nil); code != 400 {
		t.Errorf("delete self: got %d, want 400", code)
	}
	if code, _ := e.do("PUT", self, e.admin, map[string]any{"username": "admin", "role": "viewer"}); code != 400 {
		t.Errorf("demote self: got %d, want 400", code)
	}
	// A second admin can't take away the last other admin's rights either.
	code, other := e.do("POST", "/api/users", e.admin, map[string]any{"username": "ops", "role": "admin", "password": "opspassword"})
	if code != 201 {
		t.Fatalf("create second admin: %d", code)
	}
	ot := e.login("ops", "opspassword")
	if code, _ := e.do("PUT", self, ot, map[string]any{"username": "admin", "role": "operator"}); code != 200 {
		t.Errorf("demote one of two admins: got %d, want 200", code)
	}
	opsPath := "/api/users/" + itoa(int(other["id"].(float64)))
	if code, _ := e.do("DELETE", opsPath, ot, nil); code != 400 {
		t.Errorf("delete self as last admin: got %d, want 400", code)
	}
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }
