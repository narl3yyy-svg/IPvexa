package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"

	"ipvexa/internal/onvif"
	"ipvexa/internal/store"
)

// ptzHub caches one ONVIF client per camera and auto-stops movement: the client
// must repeat "move" while a button is held, so if it disappears mid-move the camera
// stops by itself instead of turning until it hits its limit.
type ptzHub struct {
	mu      sync.Mutex
	clients map[int64]*onvif.Client
	timers  map[int64]*time.Timer
}

const ptzAutoStop = 1500 * time.Millisecond

func (h *ptzHub) invalidate(id int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, id)
	if t := h.timers[id]; t != nil {
		t.Stop()
		delete(h.timers, id)
	}
}

// onvifTarget works out the device service URL and credentials for a camera.
func onvifTarget(c store.Camera) (deviceURL, user, pass string, err error) {
	u, perr := url.Parse(c.MainURL)
	if perr != nil || u.Hostname() == "" {
		return "", "", "", errors.New("camera URL has no host for ONVIF")
	}
	port := c.OnvifPort
	if port <= 0 {
		port = 80
	}
	user, pass = c.OnvifUser, c.OnvifPass
	if user == "" && u.User != nil {
		user = u.User.Username()
		pass, _ = u.User.Password()
	}
	return "http://" + net.JoinHostPort(u.Hostname(), strconv.Itoa(port)) + "/onvif/device_service", user, pass, nil
}

func (s *Server) ptzClient(r *http.Request) (int64, *onvif.Client, error) {
	id, ok := pathID(r)
	if !ok {
		return 0, nil, errors.New("bad id")
	}
	s.ptz.mu.Lock()
	defer s.ptz.mu.Unlock()
	if s.ptz.clients == nil {
		s.ptz.clients = map[int64]*onvif.Client{}
		s.ptz.timers = map[int64]*time.Timer{}
	}
	if c := s.ptz.clients[id]; c != nil {
		return id, c, nil
	}
	cam, err := s.Store.Camera(id)
	if err != nil {
		return 0, nil, errors.New("camera not found")
	}
	dev, user, pass, err := onvifTarget(cam)
	if err != nil {
		return 0, nil, err
	}
	c := onvif.New(dev, user, pass)
	s.ptz.clients[id] = c
	return id, c, nil
}

func (s *Server) ptzCheck(w http.ResponseWriter, r *http.Request) {
	_, c, err := s.ptzClient(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	presets, presetsErr, err := c.Check(r.Context())
	if err != nil {
		writeJSON(w, 200, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	resp := map[string]any{"ok": true, "presets": len(presets), "presets_supported": presetsErr == nil}
	if presetsErr != nil {
		resp["presets_error"] = presetsErr.Error()
	}
	writeJSON(w, 200, resp)
}

func (s *Server) ptzMove(w http.ResponseWriter, r *http.Request) {
	id, c, err := s.ptzClient(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	var req struct{ Pan, Tilt, Zoom float64 }
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&req); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
	if err := c.ContinuousMove(r.Context(), req.Pan, req.Tilt, req.Zoom); err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	s.ptz.mu.Lock()
	if t := s.ptz.timers[id]; t != nil {
		t.Reset(ptzAutoStop)
	} else {
		s.ptz.timers[id] = time.AfterFunc(ptzAutoStop, func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			c.Stop(ctx)
		})
	}
	s.ptz.mu.Unlock()
	w.WriteHeader(204)
}

func (s *Server) ptzStop(w http.ResponseWriter, r *http.Request) {
	id, c, err := s.ptzClient(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	s.ptz.mu.Lock()
	if t := s.ptz.timers[id]; t != nil {
		t.Stop()
		delete(s.ptz.timers, id)
	}
	s.ptz.mu.Unlock()
	if err := c.Stop(r.Context()); err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	w.WriteHeader(204)
}

func (s *Server) ptzPresets(w http.ResponseWriter, r *http.Request) {
	_, c, err := s.ptzClient(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	p, err := c.Presets(r.Context())
	if err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	writeJSON(w, 200, p)
}

func (s *Server) ptzGoto(w http.ResponseWriter, r *http.Request) {
	_, c, err := s.ptzClient(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	var req struct{ Token string }
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&req); err != nil || req.Token == "" {
		writeErr(w, 400, "bad request")
		return
	}
	if err := c.GotoPreset(r.Context(), req.Token); err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	w.WriteHeader(204)
}

func (s *Server) ptzSavePreset(w http.ResponseWriter, r *http.Request) {
	_, c, err := s.ptzClient(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	var req struct{ Name string }
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&req); err != nil || req.Name == "" {
		writeErr(w, 400, "bad request")
		return
	}
	tok, err := c.SetPreset(r.Context(), req.Name)
	if err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	writeJSON(w, 200, map[string]string{"token": tok})
}
