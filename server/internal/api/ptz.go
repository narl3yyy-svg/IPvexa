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
	"ipvexa/internal/ptzd"
	"ipvexa/internal/store"
)

// ptzPreset is the common preset shape sent to clients.
type ptzPreset struct {
	Token string `json:"token"`
	Name  string `json:"name"`
}

// ptzInfo describes what a camera's PTZ can do, so the app shows only working controls.
type ptzInfo struct {
	Protocol         string `json:"protocol"` // "onvif" | "ptzd"
	Zoom             bool   `json:"zoom"`
	PresetsSupported bool   `json:"presets_supported"`
	Presets          int    `json:"presets"`
	PresetsError     string `json:"presets_error,omitempty"`
	Actions          []string `json:"actions"` // extra buttons, e.g. "center", "home"
}

// ptzDriver is implemented once per PTZ protocol.
type ptzDriver interface {
	Move(ctx context.Context, pan, tilt, zoom float64) error
	Stop(ctx context.Context) error
	Presets(ctx context.Context) ([]ptzPreset, error)
	GotoPreset(ctx context.Context, token string) error
	SavePreset(ctx context.Context, name string) (string, error)
	Action(ctx context.Context, name string) error
	Info(ctx context.Context) (ptzInfo, error)
}

// ---- ONVIF ----

type onvifDriver struct{ c *onvif.Client }

func (d onvifDriver) Move(ctx context.Context, p, t, z float64) error { return d.c.ContinuousMove(ctx, p, t, z) }
func (d onvifDriver) Stop(ctx context.Context) error                  { return d.c.Stop(ctx) }
func (d onvifDriver) GotoPreset(ctx context.Context, tok string) error {
	return d.c.GotoPreset(ctx, tok)
}
func (d onvifDriver) SavePreset(ctx context.Context, name string) (string, error) {
	return d.c.SetPreset(ctx, name)
}
func (d onvifDriver) Action(ctx context.Context, name string) error {
	return errors.New("not available over ONVIF")
}
func (d onvifDriver) Presets(ctx context.Context) ([]ptzPreset, error) {
	ps, err := d.c.Presets(ctx)
	out := make([]ptzPreset, 0, len(ps))
	for _, p := range ps {
		out = append(out, ptzPreset{p.Token, p.Name})
	}
	return out, err
}
func (d onvifDriver) Info(ctx context.Context) (ptzInfo, error) {
	presets, presetsErr, err := d.c.Check(ctx)
	if err != nil {
		return ptzInfo{}, err
	}
	info := ptzInfo{Protocol: "onvif", Zoom: true, PresetsSupported: presetsErr == nil, Presets: len(presets), Actions: []string{}}
	if presetsErr != nil {
		info.PresetsError = presetsErr.Error()
	}
	return info, nil
}

// ---- OpenIPC ptzd ----

type ptzdDriver struct{ c *ptzd.Client }

func (d ptzdDriver) Move(ctx context.Context, p, t, z float64) error { return d.c.Move(ctx, p, t, z) }
func (d ptzdDriver) Stop(ctx context.Context) error                  { return d.c.Stop(ctx) }
func (d ptzdDriver) GotoPreset(ctx context.Context, tok string) error {
	return d.c.GotoPreset(ctx, tok)
}
func (d ptzdDriver) SavePreset(ctx context.Context, name string) (string, error) {
	return d.c.SavePreset(ctx, name)
}
func (d ptzdDriver) Action(ctx context.Context, name string) error { return d.c.Action(ctx, name) }
func (d ptzdDriver) Presets(ctx context.Context) ([]ptzPreset, error) {
	ps, err := d.c.Presets(ctx)
	out := make([]ptzPreset, 0, len(ps))
	for _, p := range ps {
		out = append(out, ptzPreset{strconv.Itoa(p.ID), p.Name})
	}
	return out, err
}
func (d ptzdDriver) Info(ctx context.Context) (ptzInfo, error) {
	st, err := d.c.Probe(ctx)
	if err != nil {
		return ptzInfo{}, err
	}
	return ptzInfo{Protocol: "ptzd", Zoom: false, PresetsSupported: true, Presets: len(st.Presets), Actions: []string{"center", "home"}}, nil
}

// ---- per-camera cache + safety auto-stop ----

// ptzHub caches one driver per camera and auto-stops movement: the app repeats
// "move" while a button is held, so if it disappears mid-move the camera stops by
// itself instead of turning until it hits its limit.
type ptzHub struct {
	mu      sync.Mutex
	drivers map[int64]ptzDriver
	timers  map[int64]*time.Timer
}

const ptzAutoStop = 1500 * time.Millisecond

func (h *ptzHub) invalidate(id int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.drivers, id)
	if t := h.timers[id]; t != nil {
		t.Stop()
		delete(h.timers, id)
	}
}

// ptzTarget works out the camera's host, control port and login.
func ptzTarget(c store.Camera) (host string, port int, user, pass string, err error) {
	u, perr := url.Parse(c.MainURL)
	if perr != nil || u.Hostname() == "" {
		return "", 0, "", "", errors.New("camera URL has no host for PTZ")
	}
	port = c.OnvifPort
	if port <= 0 {
		port = 80
	}
	user, pass = c.OnvifUser, c.OnvifPass
	if user == "" && u.User != nil {
		user = u.User.Username()
		pass, _ = u.User.Password()
	}
	return u.Hostname(), port, user, pass, nil
}

func (s *Server) ptzDriverFor(ctx context.Context, r *http.Request) (int64, ptzDriver, error) {
	id, ok := pathID(r)
	if !ok {
		return 0, nil, errors.New("bad id")
	}
	s.ptz.mu.Lock()
	if s.ptz.drivers == nil {
		s.ptz.drivers = map[int64]ptzDriver{}
		s.ptz.timers = map[int64]*time.Timer{}
	}
	if d := s.ptz.drivers[id]; d != nil {
		s.ptz.mu.Unlock()
		return id, d, nil
	}
	s.ptz.mu.Unlock()

	cam, err := s.Store.Camera(id)
	if err != nil {
		return 0, nil, errors.New("camera not found")
	}
	host, port, user, pass, err := ptzTarget(cam)
	if err != nil {
		return 0, nil, err
	}
	hp := net.JoinHostPort(host, strconv.Itoa(port))
	pd := ptzdDriver{ptzd.New("http://"+hp, user, pass)}
	od := onvifDriver{onvif.New("http://"+hp+"/onvif/device_service", user, pass)}

	var d ptzDriver
	switch cam.PTZProtocol {
	case "ptzd":
		d = pd
	case "onvif":
		d = od
	default: // auto: prefer ptzd when the camera has it (it drives the real motors on OpenIPC)
		pctx, cancel := context.WithTimeout(ctx, 4*time.Second)
		_, perr := pd.c.Probe(pctx)
		cancel()
		if perr == nil {
			d = pd
		} else {
			d = od
		}
	}
	s.ptz.mu.Lock()
	s.ptz.drivers[id] = d
	s.ptz.mu.Unlock()
	return id, d, nil
}

func (s *Server) ptzCheck(w http.ResponseWriter, r *http.Request) {
	_, d, err := s.ptzDriverFor(r.Context(), r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	info, err := d.Info(r.Context())
	if err != nil {
		writeJSON(w, 200, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "protocol": info.Protocol, "zoom": info.Zoom,
		"presets_supported": info.PresetsSupported, "presets": info.Presets,
		"presets_error": info.PresetsError, "actions": info.Actions})
}

func (s *Server) ptzMove(w http.ResponseWriter, r *http.Request) {
	id, d, err := s.ptzDriverFor(r.Context(), r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	var req struct{ Pan, Tilt, Zoom float64 }
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&req); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
	if err := d.Move(r.Context(), req.Pan, req.Tilt, req.Zoom); err != nil {
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
			d.Stop(ctx)
		})
	}
	s.ptz.mu.Unlock()
	w.WriteHeader(204)
}

func (s *Server) ptzStop(w http.ResponseWriter, r *http.Request) {
	id, d, err := s.ptzDriverFor(r.Context(), r)
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
	if err := d.Stop(r.Context()); err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	w.WriteHeader(204)
}

func (s *Server) ptzPresets(w http.ResponseWriter, r *http.Request) {
	_, d, err := s.ptzDriverFor(r.Context(), r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	p, err := d.Presets(r.Context())
	if err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	writeJSON(w, 200, p)
}

func (s *Server) ptzGoto(w http.ResponseWriter, r *http.Request) {
	_, d, err := s.ptzDriverFor(r.Context(), r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	var req struct{ Token string }
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&req); err != nil || req.Token == "" {
		writeErr(w, 400, "bad request")
		return
	}
	if err := d.GotoPreset(r.Context(), req.Token); err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	w.WriteHeader(204)
}

func (s *Server) ptzSavePreset(w http.ResponseWriter, r *http.Request) {
	_, d, err := s.ptzDriverFor(r.Context(), r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	var req struct{ Name string }
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&req); err != nil || req.Name == "" {
		writeErr(w, 400, "bad request")
		return
	}
	tok, err := d.SavePreset(r.Context(), req.Name)
	if err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	writeJSON(w, 200, map[string]string{"token": tok})
}

func (s *Server) ptzAction(w http.ResponseWriter, r *http.Request) {
	_, d, err := s.ptzDriverFor(r.Context(), r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	var req struct{ Action string }
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&req); err != nil || req.Action == "" {
		writeErr(w, 400, "bad request")
		return
	}
	if err := d.Action(r.Context(), req.Action); err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	w.WriteHeader(204)
}
