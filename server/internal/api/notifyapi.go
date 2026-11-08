package api

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"

	"ipvexa/internal/notify"
	"ipvexa/internal/store"
)

// feedAuth checks a phone's credentials for the notification feed: Basic auth with
// an IPvexa account, or a session token (Bearer header, or ntfy's ?auth= parameter).
// Only accounts that may see every camera can subscribe, because alerts cover all cameras.
func (s *Server) feedAuth(r *http.Request) bool {
	h := r.Header.Get("Authorization")
	if a := r.URL.Query().Get("auth"); a != "" && h == "" {
		if dec, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(a, "=")); err == nil {
			h = string(dec)
		}
	}
	var u store.User
	var err error
	switch {
	case strings.HasPrefix(h, "Bearer "):
		u, err = s.Store.SessionUser(strings.TrimPrefix(h, "Bearer "))
	case strings.HasPrefix(h, "Basic "):
		user, pass, ok := r.BasicAuth()
		if !ok {
			// came from ?auth=: parse it ourselves
			raw, derr := base64.StdEncoding.DecodeString(strings.TrimPrefix(h, "Basic "))
			if derr != nil {
				return false
			}
			user, pass, ok = strings.Cut(string(raw), ":")
			if !ok {
				return false
			}
		}
		u, err = s.Store.UserByName(strings.TrimSpace(user))
		if err == nil && bcrypt.CompareHashAndPassword([]byte(u.Hash), []byte(pass)) != nil {
			err = store.ErrNotFound
		}
	default:
		return false
	}
	if err != nil || u.Disabled || !u.Effective().AllCameras {
		time.Sleep(300 * time.Millisecond) // slow down guessing
		return false
	}
	return true
}

type notifySettings struct {
	Topic string        `json:"topic"`
	Rules []notify.Rule `json:"rules"`
}

func (s *Server) getNotify(w http.ResponseWriter, r *http.Request) {
	if s.Notify == nil {
		writeErr(w, 503, "notifications are not available")
		return
	}
	writeJSON(w, 200, notifySettings{Topic: s.Notify.Topic(), Rules: s.Notify.Rules()})
}

func (s *Server) putNotify(w http.ResponseWriter, r *http.Request) {
	if s.Notify == nil {
		writeErr(w, 503, "notifications are not available")
		return
	}
	var req notifySettings
	if err := json.NewDecoder(io.LimitReader(r.Body, 256<<10)).Decode(&req); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
	if req.Rules == nil {
		req.Rules = []notify.Rule{}
	}
	if err := s.Notify.SetRules(req.Rules); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if t := strings.TrimSpace(req.Topic); t != "" && t != s.Notify.Topic() {
		if !usernameRE.MatchString(t) || strings.ContainsAny(t, "@.") || len(t) < 6 {
			writeErr(w, 400, "the feed name must be 6–32 letters, digits, - or _")
			return
		}
		s.Store.SetSetting("ntfy_topic", t)
	}
	s.audit(r, "notifications.update", "")
	s.getNotify(w, r)
}

func (s *Server) testNotify(w http.ResponseWriter, r *http.Request) {
	if s.Notify == nil {
		writeErr(w, 503, "notifications are not available")
		return
	}
	m := s.Notify.Publish(notify.Message{Title: "IPvexa test", Message: "Notifications are working. Sent by " + currentUser(r).Username + ".",
		Priority: 3, Tags: []string{"tada"}})
	writeJSON(w, 200, m)
}
