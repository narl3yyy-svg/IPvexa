package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strings"

	"golang.org/x/crypto/bcrypt"

	"ipvexa/internal/store"
)

// User management (admins) and password changes (everyone).

var usernameRE = regexp.MustCompile(`^[A-Za-z0-9._@-]{1,32}$`)

const minPasswordLen = 8

type userRequest struct {
	Username    string             `json:"username"`
	FullName    string             `json:"full_name"`
	Role        string             `json:"role"`
	Password    string             `json:"password"` // empty on update = unchanged
	Disabled    bool               `json:"disabled"`
	Permissions *store.Permissions `json:"permissions"`
}

func hashPassword(pw string) (string, error) {
	if len(pw) < minPasswordLen {
		return "", errors.New("password must be at least 8 characters")
	}
	h, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.DefaultCost)
	return string(h), err
}

func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	users, err := s.Store.Users()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, users)
}

func decodeUser(r *http.Request) (userRequest, error) {
	var req userRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&req); err != nil {
		return req, errors.New("bad request")
	}
	req.Username = strings.TrimSpace(req.Username)
	req.FullName = strings.TrimSpace(req.FullName)
	if !usernameRE.MatchString(req.Username) {
		return req, errors.New("username must be 1–32 letters, digits or . _ @ -")
	}
	if _, ok := roleRank[req.Role]; !ok {
		return req, errors.New("role must be admin, operator or viewer")
	}
	return req, nil
}

func (s *Server) createUser(w http.ResponseWriter, r *http.Request) {
	req, err := decodeUser(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if _, err := s.Store.UserByName(req.Username); err == nil {
		writeErr(w, 409, "a user with that name already exists")
		return
	}
	hash, err := hashPassword(req.Password)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	u := store.User{Username: req.Username, FullName: req.FullName, Hash: hash, Role: req.Role, Disabled: req.Disabled,
		Perms: store.DefaultPermissions(req.Role)}
	if req.Permissions != nil {
		u.Perms = *req.Permissions
	}
	if err := s.Store.CreateUser(&u); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	s.audit(r, "user.create", u.Username+" ("+u.Role+")")
	writeJSON(w, 201, u)
}

func (s *Server) updateUser(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	old, err := s.Store.UserByID(id)
	if err != nil {
		writeErr(w, 404, "user not found")
		return
	}
	req, err := decodeUser(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if other, err := s.Store.UserByName(req.Username); err == nil && other.ID != id {
		writeErr(w, 409, "a user with that name already exists")
		return
	}
	me := currentUser(r)
	losesAdmin := old.Role == "admin" && !old.Disabled && (req.Role != "admin" || req.Disabled)
	if losesAdmin {
		if id == me.ID {
			writeErr(w, 400, "you can't remove your own admin rights or disable your own account")
			return
		}
		if n, _ := s.Store.ActiveAdminCount(); n <= 1 {
			writeErr(w, 400, "there must always be at least one enabled admin")
			return
		}
	}
	u := old
	u.Username, u.FullName, u.Role, u.Disabled = req.Username, req.FullName, req.Role, req.Disabled
	if req.Permissions != nil {
		u.Perms = *req.Permissions
	}
	if err := s.Store.UpdateUser(u); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	if req.Password != "" {
		hash, err := hashPassword(req.Password)
		if err != nil {
			writeErr(w, 400, err.Error())
			return
		}
		if err := s.Store.SetUserHashByID(id, hash); err != nil {
			writeErr(w, 500, err.Error())
			return
		}
	}
	// A new password or a disabled account signs the user out everywhere.
	if req.Password != "" || (u.Disabled && !old.Disabled) {
		keep := ""
		if id == me.ID {
			keep = bearerToken(r)
		}
		s.Store.DeleteUserSessions(id, keep)
	}
	detail := u.Username + " (" + u.Role + ")"
	if req.Password != "" {
		detail += ", password reset"
	}
	if u.Disabled {
		detail += ", disabled"
	}
	s.audit(r, "user.update", detail)
	writeJSON(w, 200, u)
}

func (s *Server) deleteUser(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	if id == currentUser(r).ID {
		writeErr(w, 400, "you can't delete your own account")
		return
	}
	u, err := s.Store.UserByID(id)
	if err != nil {
		writeErr(w, 404, "user not found")
		return
	}
	if u.Role == "admin" && !u.Disabled {
		if n, _ := s.Store.ActiveAdminCount(); n <= 1 {
			writeErr(w, 400, "there must always be at least one enabled admin")
			return
		}
	}
	if err := s.Store.DeleteUser(id); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	s.audit(r, "user.delete", u.Username)
	w.WriteHeader(204)
}

func (s *Server) changeOwnPassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Current string `json:"current"`
		New     string `json:"new"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
	me := currentUser(r)
	if bcrypt.CompareHashAndPassword([]byte(me.Hash), []byte(req.Current)) != nil {
		writeErr(w, 403, "current password is wrong")
		return
	}
	hash, err := hashPassword(req.New)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if err := s.Store.SetUserHashByID(me.ID, hash); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	s.Store.DeleteUserSessions(me.ID, bearerToken(r))
	s.audit(r, "password.change", "")
	w.WriteHeader(204)
}

func bearerToken(r *http.Request) string {
	if t := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "); t != r.Header.Get("Authorization") {
		return t
	}
	return r.URL.Query().Get("token")
}
