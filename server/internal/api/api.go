// Package api is Ipvexa's HTTP interface, used by the desktop client and (later) the web/phone UI.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"

	"ipvexa/internal/camera"
	"ipvexa/internal/discovery"
	"ipvexa/internal/storage"
	"ipvexa/internal/store"
)

const Version = "0.1.0"

type Server struct {
	Store   *store.Store
	Cams    *camera.Manager
	RecRoot string
	FFmpeg  string

	ptz ptzHub
}

type ctxKey struct{}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/info", s.info)
	mux.HandleFunc("POST /api/login", s.login)

	auth := func(role string, h http.HandlerFunc) http.Handler { return s.requireAuth(role, h) }
	mux.Handle("POST /api/logout", auth("viewer", s.logout))
	mux.Handle("GET /api/me", auth("viewer", s.me))
	mux.Handle("GET /api/system", auth("viewer", s.system))
	mux.Handle("GET /api/cameras", auth("viewer", s.listCameras))
	mux.Handle("POST /api/cameras", auth("admin", s.createCamera))
	mux.Handle("GET /api/cameras/{id}", auth("viewer", s.getCamera))
	mux.Handle("PUT /api/cameras/{id}", auth("admin", s.updateCamera))
	mux.Handle("DELETE /api/cameras/{id}", auth("admin", s.deleteCamera))
	mux.Handle("GET /api/cameras/{id}/log", auth("admin", s.cameraLog))
	mux.Handle("GET /api/cameras/{id}/live", auth("viewer", s.live))
	mux.Handle("GET /api/cameras/{id}/snapshot", auth("viewer", s.snapshot))
	mux.Handle("GET /api/cameras/{id}/timeline", auth("viewer", s.timeline))
	mux.Handle("GET /api/cameras/{id}/playback", auth("viewer", s.playback))
	mux.Handle("GET /api/discover", auth("admin", s.discover))
	mux.Handle("GET /api/cameras/{id}/ptz/check", auth("operator", s.ptzCheck))
	mux.Handle("POST /api/cameras/{id}/ptz/move", auth("operator", s.ptzMove))
	mux.Handle("POST /api/cameras/{id}/ptz/stop", auth("operator", s.ptzStop))
	mux.Handle("GET /api/cameras/{id}/ptz/presets", auth("viewer", s.ptzPresets))
	mux.Handle("POST /api/cameras/{id}/ptz/goto", auth("operator", s.ptzGoto))
	mux.Handle("POST /api/cameras/{id}/ptz/presets", auth("operator", s.ptzSavePreset))
	mux.Handle("POST /api/cameras/{id}/ptz/action", auth("operator", s.ptzAction))
	return logRequests(mux)
}

// ---------- helpers ----------

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func pathID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id, err == nil
}

func queryInt(r *http.Request, key string, def int64) int64 {
	v, err := strconv.ParseInt(r.URL.Query().Get(key), 10, 64)
	if err != nil {
		return def
	}
	return v
}

func logRequests(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		h.ServeHTTP(w, r)
		if !strings.HasSuffix(r.URL.Path, "/live") && !strings.HasSuffix(r.URL.Path, "/playback") {
			slog.Debug("http", "method", r.Method, "path", r.URL.Path, "dur", time.Since(start))
		}
	})
}

var roleRank = map[string]int{"viewer": 1, "operator": 2, "admin": 3}

func (s *Server) requireAuth(role string, h http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if tok == "" || tok == r.Header.Get("Authorization") {
			tok = r.URL.Query().Get("token")
		}
		u, err := s.Store.SessionUser(tok)
		if tok == "" || err != nil {
			writeErr(w, http.StatusUnauthorized, "login required")
			return
		}
		if roleRank[u.Role] < roleRank[role] {
			writeErr(w, http.StatusForbidden, "insufficient permissions")
			return
		}
		h(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, u)))
	})
}

func currentUser(r *http.Request) store.User {
	u, _ := r.Context().Value(ctxKey{}).(store.User)
	return u
}

// ---------- auth ----------

func (s *Server) info(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"name": "Ipvexa", "version": Version, "server_time": time.Now().UnixMilli()})
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var req struct{ Username, Password string }
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
	u, err := s.Store.UserByName(strings.TrimSpace(req.Username))
	ok := err == nil && bcrypt.CompareHashAndPassword([]byte(u.Hash), []byte(req.Password)) == nil
	if !ok && err == nil {
		// Passwords copied from a terminal often pick up a stray space or newline.
		if t := strings.TrimSpace(req.Password); t != req.Password {
			ok = bcrypt.CompareHashAndPassword([]byte(u.Hash), []byte(t)) == nil
		}
	}
	if !ok {
		time.Sleep(500 * time.Millisecond) // slow down guessing
		writeErr(w, 401, "wrong username or password")
		return
	}
	tok, err := s.Store.NewSession(u.ID, 30*24*time.Hour)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"token": tok, "user": u})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	s.Store.DeleteSession(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	w.WriteHeader(204)
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, currentUser(r)) }

// ---------- system ----------

func (s *Server) system(w http.ResponseWriter, r *http.Request) {
	du, _ := storage.Usage(s.RecRoot)
	cams, _ := s.Store.Cameras()
	type camStat struct {
		ID       int64 `json:"id"`
		Segments int64 `json:"segments"`
		Bytes    int64 `json:"bytes"`
		Oldest   int64 `json:"oldest"`
	}
	stats := []camStat{}
	for _, c := range cams {
		n, b, o, _ := s.Store.RecordingStats(c.ID)
		stats = append(stats, camStat{c.ID, n, b, o})
	}
	writeJSON(w, 200, map[string]any{"version": Version, "server_time": time.Now().UnixMilli(), "disk": du, "recordings": stats})
}

// ---------- cameras ----------

type cameraView struct {
	store.Camera
	Status camera.CameraStatus `json:"status"`
}

func (s *Server) listCameras(w http.ResponseWriter, r *http.Request) {
	cams, err := s.Store.Cameras()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	admin := currentUser(r).Role == "admin"
	out := make([]cameraView, 0, len(cams))
	for _, c := range cams {
		c.OnvifPass = ""
		if !admin {
			c.MainURL, c.SubURL = redact(c.MainURL), redact(c.SubURL)
		}
		out = append(out, cameraView{c, s.Cams.Status(c.ID)})
	}
	writeJSON(w, 200, out)
}

// redact hides camera passwords from non-admin users.
func redact(u string) string {
	at := strings.Index(u, "@")
	sch := strings.Index(u, "://")
	if at < 0 || sch < 0 || at < sch {
		return u
	}
	return u[:sch+3] + "***@" + u[at+1:]
}

func (s *Server) getCamera(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	c, err := s.Store.Camera(id)
	if err != nil {
		writeErr(w, 404, "camera not found")
		return
	}
	if currentUser(r).Role != "admin" {
		c.MainURL, c.SubURL = redact(c.MainURL), redact(c.SubURL)
	}
	c.OnvifPass = ""
	writeJSON(w, 200, cameraView{c, s.Cams.Status(c.ID)})
}

func normalize(c *store.Camera) error {
	c.Name = strings.TrimSpace(c.Name)
	c.MainURL = strings.TrimSpace(c.MainURL)
	c.SubURL = strings.TrimSpace(c.SubURL)
	if c.Name == "" || c.MainURL == "" {
		return errors.New("name and main_url are required")
	}
	if c.Brand == "" {
		c.Brand = "generic"
	}
	if c.Transport != "udp" {
		c.Transport = "tcp"
	}
	// Recording is opt-in: a new camera only records when asked to.
	if c.RecordMode != "continuous" {
		c.RecordMode = "off"
	}
	if c.OnvifPort <= 0 || c.OnvifPort > 65535 {
		c.OnvifPort = 80
	}
	c.OnvifUser = strings.TrimSpace(c.OnvifUser)
	if c.PTZProtocol != "onvif" && c.PTZProtocol != "ptzd" {
		c.PTZProtocol = "auto"
	}
	if c.RetentionDays < 0 {
		c.RetentionDays = 0
	}
	return nil
}

func (s *Server) createCamera(w http.ResponseWriter, r *http.Request) {
	c := store.Camera{Enabled: true, RetentionDays: 30}
	if err := json.NewDecoder(io.LimitReader(r.Body, 65536)).Decode(&c); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
	if err := normalize(&c); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if err := s.Store.CreateCamera(&c); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	s.Cams.Apply(c)
	c.OnvifPass = ""
	writeJSON(w, 201, c)
}

func (s *Server) updateCamera(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	c, err := s.Store.Camera(id)
	if err != nil {
		writeErr(w, 404, "camera not found")
		return
	}
	oldPass := c.OnvifPass
	c.OnvifPass = ""
	if err := json.NewDecoder(io.LimitReader(r.Body, 65536)).Decode(&c); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
	if c.OnvifPass == "" && c.OnvifUser != "" {
		c.OnvifPass = oldPass // not sent back to clients, so an empty field means "unchanged"
	}
	c.ID = id
	if err := normalize(&c); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if err := s.Store.UpdateCamera(&c); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	s.ptz.invalidate(id)
	go s.Cams.Apply(c)
	c.OnvifPass = ""
	writeJSON(w, 200, c)
}

func (s *Server) deleteCamera(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	s.Cams.Stop(id)
	s.ptz.invalidate(id)
	if err := s.Store.DeleteCamera(id); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	w.WriteHeader(204)
}

func (s *Server) cameraLog(w http.ResponseWriter, r *http.Request) {
	id, _ := pathID(r)
	writeJSON(w, 200, s.Cams.Log(id, r.URL.Query().Get("stream")))
}

func (s *Server) discover(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	devs, err := discovery.Probe(ctx)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, devs)
}

// ---------- live ----------

func (s *Server) live(w http.ResponseWriter, r *http.Request) {
	id, _ := pathID(r)
	hub := s.Cams.Hub(id, r.URL.Query().Get("stream"))
	if hub == nil {
		writeErr(w, 404, "camera not running")
		return
	}
	sub := hub.Subscribe()
	defer sub.Close()
	w.Header().Set("Content-Type", "video/mp2t")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(200)
	fl, _ := w.(http.Flusher)
	for {
		select {
		case <-r.Context().Done():
			return
		case b, ok := <-sub.C:
			if !ok {
				return
			}
			if _, err := w.Write(b); err != nil {
				return
			}
			if fl != nil {
				fl.Flush()
			}
		}
	}
}

// snapshot decodes one frame from the live stream as JPEG.
func (s *Server) snapshot(w http.ResponseWriter, r *http.Request) {
	id, _ := pathID(r)
	stream := r.URL.Query().Get("stream")
	if stream == "" {
		stream = "sub"
	}
	hub := s.Cams.Hub(id, stream)
	if hub == nil {
		writeErr(w, 404, "camera not running")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.FFmpeg, "-hide_banner", "-loglevel", "error", "-f", "mpegts", "-i", "pipe:0",
		"-frames:v", "1", "-vf", "scale='min(640,iw)':-2", "-q:v", "4", "-f", "image2", "-c:v", "mjpeg", "pipe:1")
	stdin, _ := cmd.StdinPipe()
	sub := hub.Subscribe()
	defer sub.Close()
	go func() {
		defer stdin.Close()
		for {
			select {
			case <-ctx.Done():
				return
			case b, ok := <-sub.C:
				if !ok {
					return
				}
				if _, err := stdin.Write(b); err != nil {
					return
				}
			}
		}
	}()
	img, err := cmd.Output()
	if err != nil || len(img) == 0 {
		writeErr(w, 504, "no frame available")
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(img)
}

// ---------- recordings ----------

const gapTolerance = 3000 // ms; segments closer than this count as continuous

// timeline returns merged recorded ranges for drawing on the client's timeline.
func (s *Server) timeline(w http.ResponseWriter, r *http.Request) {
	id, _ := pathID(r)
	now := time.Now().UnixMilli()
	from := queryInt(r, "from", now-24*3600*1000)
	to := queryInt(r, "to", now)
	stream := r.URL.Query().Get("stream")
	if stream != "sub" {
		stream = "main"
	}
	segs, err := s.Store.Segments(id, stream, from, to)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	chunks := [][2]int64{}
	add := func(a, b int64) {
		if n := len(chunks); n > 0 && a-chunks[n-1][1] <= gapTolerance {
			chunks[n-1][1] = max(chunks[n-1][1], b)
			return
		}
		chunks = append(chunks, [2]int64{a, b})
	}
	for _, g := range segs {
		add(g.Start, g.End)
	}
	if _, start, ok := s.Cams.OpenSegment(id, stream); ok && start < to {
		add(start, now)
	}
	writeJSON(w, 200, map[string]any{"from": from, "to": to, "chunks": chunks})
}

// tsOffset shifts playback timestamps so frames before the seek point (from the
// preceding keyframe) never go negative. Clients subtract it: wall = start + (pts - tsOffset).
const tsOffset = 60

// playback streams recorded video starting at ?t= (unix ms) as MPEG-TS, without re-encoding.
// It covers one continuous run of segments; when it ends the client requests the next run.
// Response headers tell the client how to map timestamps back to wall-clock time.
func (s *Server) playback(w http.ResponseWriter, r *http.Request) {
	id, _ := pathID(r)
	t := queryInt(r, "t", 0)
	stream := r.URL.Query().Get("stream")
	if stream != "sub" {
		stream = "main"
	}
	segs, err := s.Store.Segments(id, stream, t, t+6*3600*1000)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	type part struct {
		path       string
		start, end int64 // end = 0 for the open segment
	}
	var run []part
	for _, g := range segs {
		if n := len(run); n > 0 && g.Start-run[n-1].end > gapTolerance {
			break
		}
		run = append(run, part{filepath.Join(s.RecRoot, g.Path), g.Start, g.End})
	}
	if p, start, ok := s.Cams.OpenSegment(id, stream); ok {
		if n := len(run); (n == 0 && start <= t+gapTolerance) || (n > 0 && start-run[n-1].end <= gapTolerance) {
			run = append(run, part{p, start, 0})
		} else if n == 0 && start > t {
			run = append(run, part{p, start, 0})
		}
	}
	if len(run) == 0 {
		writeErr(w, 404, "no recording at or after this time")
		return
	}

	startWall := max(t, run[0].start)
	last := run[len(run)-1]
	runEnd := last.end
	if runEnd == 0 {
		runEnd = time.Now().UnixMilli()
	}
	if r.URL.Query().Get("info") == "1" {
		writeJSON(w, 200, map[string]any{"start": startWall, "run_end": runEnd, "open": last.end == 0, "ts_offset": tsOffset})
		return
	}
	var list strings.Builder
	list.WriteString("ffconcat version 1.0\n")
	for i, p := range run {
		fmt.Fprintf(&list, "file '%s'\n", strings.ReplaceAll(p.path, "'", `'\''`))
		if i == 0 && startWall > p.start {
			fmt.Fprintf(&list, "inpoint %.3f\n", float64(startWall-p.start)/1000)
		}
		if p.end > 0 {
			fmt.Fprintf(&list, "duration %.3f\n", float64(p.end-p.start)/1000)
		}
	}
	tmp, err := os.CreateTemp("", "ipvexa-play-*.ffconcat")
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	tmp.WriteString(list.String())
	tmp.Close()
	defer os.Remove(tmp.Name())

	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin",
		"-f", "concat", "-safe", "0", "-i", tmp.Name(),
		"-map", "0:v:0", "-c:v", "copy"}
	if r.URL.Query().Get("keyframes") == "1" {
		// For fast-forward: send only keyframes so the client isn't decoding hundreds of fps.
		args = append(args, "-bsf:v", "noise=drop=not(key),dump_extra=freq=keyframe")
	} else {
		args = append(args, "-bsf:v", "dump_extra=freq=keyframe")
	}
	args = append(args, "-copyts", "-output_ts_offset", strconv.Itoa(tsOffset),
		"-muxdelay", "0", "-muxpreload", "0", "-f", "mpegts", "pipe:1")

	cmd := exec.CommandContext(r.Context(), s.FFmpeg, args...)
	cmd.WaitDelay = 2 * time.Second
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	w.Header().Set("Content-Type", "video/mp2t")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Ipvexa-Start", strconv.FormatInt(startWall, 10))
	w.Header().Set("X-Ipvexa-Ts-Offset", strconv.Itoa(tsOffset))
	w.Header().Set("X-Ipvexa-Run-End", strconv.FormatInt(runEnd, 10))
	w.Header().Set("X-Ipvexa-Open", strconv.FormatBool(last.end == 0))
	w.WriteHeader(200)
	fl, _ := w.(http.Flusher)
	buf := make([]byte, 64*1024)
	for {
		n, err := stdout.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				break
			}
			if fl != nil {
				fl.Flush()
			}
		}
		if err != nil {
			break
		}
	}
	cmd.Wait()
	if msg := strings.TrimSpace(stderr.String()); msg != "" && r.Context().Err() == nil {
		slog.Debug("playback ffmpeg", "camera", id, "msg", msg)
	}
}
