// Package api is IPvexa's HTTP interface, used by the desktop client, the web view and phones.
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
	"ipvexa/internal/motion"
	"ipvexa/internal/notify"
	"ipvexa/internal/storage"
	"ipvexa/internal/store"
	"ipvexa/internal/web"
)

const Version = "0.3.0"

type Server struct {
	Store   *store.Store
	Cams    *camera.Manager
	RecRoot string
	DataDir string
	FFmpeg  string
	// MinFreePct is the default minimum free disk space (the -min-free flag).
	MinFreePct float64
	Notify     *notify.Notifier // optional
	// ThumbDir holds event thumbnails (optional).
	ThumbDir string

	ptz ptzHub
}

type ctxKey struct{}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/info", s.info)
	mux.HandleFunc("POST /api/login", s.login)
	web.Register(mux)
	if s.Notify != nil {
		s.Notify.Auth = s.feedAuth
		s.Notify.Register(mux)
	}

	auth := func(role string, h http.HandlerFunc) http.Handler { return s.requireAuth(role, h) }
	mux.Handle("POST /api/logout", auth("viewer", s.logout))
	mux.Handle("GET /api/me", auth("viewer", s.me))
	mux.Handle("POST /api/me/password", auth("viewer", s.changeOwnPassword))
	mux.Handle("GET /api/system", auth("viewer", s.system))
	mux.Handle("GET /api/cameras", auth("viewer", s.listCameras))
	mux.Handle("POST /api/cameras", auth("admin", s.createCamera))
	mux.Handle("GET /api/cameras/{id}", auth("viewer", s.camPerm("", s.getCamera)))
	mux.Handle("PUT /api/cameras/{id}", auth("admin", s.updateCamera))
	mux.Handle("DELETE /api/cameras/{id}", auth("admin", s.deleteCamera))
	mux.Handle("GET /api/cameras/{id}/log", auth("admin", s.cameraLog))
	mux.Handle("GET /api/cameras/{id}/live", auth("viewer", s.camPerm("", s.live)))
	mux.Handle("GET /api/cameras/{id}/snapshot", auth("viewer", s.camPerm("", s.snapshot)))
	mux.Handle("GET /api/cameras/{id}/mjpeg", auth("viewer", s.camPerm("", s.mjpeg)))
	mux.Handle("GET /api/cameras/{id}/fmp4", auth("viewer", s.camPerm("", s.fmp4)))
	mux.Handle("GET /api/cameras/{id}/timeline", auth("viewer", s.camPerm("playback", s.timeline)))
	mux.Handle("GET /api/cameras/{id}/playback", auth("viewer", s.camPerm("playback", s.playback)))
	mux.Handle("GET /api/discover", auth("admin", s.discover))
	mux.Handle("POST /api/onvif/probe", auth("admin", s.onvifProbe))
	mux.Handle("GET /api/cameras/{id}/ptz/check", auth("viewer", s.camPerm("ptz", s.ptzCheck)))
	mux.Handle("POST /api/cameras/{id}/ptz/move", auth("viewer", s.camPerm("ptz", s.ptzMove)))
	mux.Handle("POST /api/cameras/{id}/ptz/stop", auth("viewer", s.camPerm("ptz", s.ptzStop)))
	mux.Handle("GET /api/cameras/{id}/ptz/presets", auth("viewer", s.camPerm("ptz", s.ptzPresets)))
	mux.Handle("POST /api/cameras/{id}/ptz/goto", auth("viewer", s.camPerm("ptz", s.ptzGoto)))
	mux.Handle("POST /api/cameras/{id}/ptz/presets", auth("viewer", s.camPerm("ptz", s.ptzSavePreset)))
	mux.Handle("POST /api/cameras/{id}/ptz/action", auth("viewer", s.camPerm("ptz", s.ptzAction)))
	mux.Handle("GET /api/events", auth("viewer", s.listEvents))
	mux.Handle("POST /api/cameras/{id}/bookmarks", auth("viewer", s.camPerm("playback", s.addBookmark)))
	mux.Handle("PUT /api/events/{id}", auth("viewer", s.updateEvent))
	mux.Handle("GET /api/events/{id}/thumb", auth("viewer", s.eventThumb))
	mux.Handle("DELETE /api/events/{id}", auth("viewer", s.deleteEvent))
	mux.Handle("GET /api/cameras/{id}/export", auth("viewer", s.camPerm("export", s.export)))
	mux.Handle("GET /api/audit", auth("admin", s.auditLog))
	mux.Handle("GET /api/settings", auth("admin", s.getSettings))
	mux.Handle("PUT /api/settings", auth("admin", s.putSettings))
	mux.Handle("GET /api/notify", auth("admin", s.getNotify))
	mux.Handle("PUT /api/notify", auth("admin", s.putNotify))
	mux.Handle("POST /api/notify/test", auth("admin", s.testNotify))
	mux.Handle("GET /api/users", auth("admin", s.listUsers))
	mux.Handle("POST /api/users", auth("admin", s.createUser))
	mux.Handle("PUT /api/users/{id}", auth("admin", s.updateUser))
	mux.Handle("DELETE /api/users/{id}", auth("admin", s.deleteUser))
	return logRequests(mux)
}

// camPerm checks that the signed-in user may use the camera in the path and, when need
// is "playback" or "ptz", that they hold that permission.
func (s *Server) camPerm(need string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, ok := pathID(r)
		if !ok {
			writeErr(w, 400, "bad id")
			return
		}
		p := currentUser(r).Effective()
		if !p.CanSee(id) {
			writeErr(w, 404, "camera not found")
			return
		}
		switch {
		case need == "playback" && !p.Playback:
			writeErr(w, 403, "your account is not allowed to view recordings")
			return
		case need == "ptz" && !p.PTZ:
			writeErr(w, 403, "your account is not allowed to control PTZ")
			return
		case need == "export" && (!p.Playback || !p.Export):
			writeErr(w, 403, "your account is not allowed to export video")
			return
		}
		h(w, r)
	}
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
		if tok == "" || err != nil || u.Disabled {
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
	writeJSON(w, 200, map[string]any{"name": "IPvexa", "version": Version, "server_time": time.Now().UnixMilli()})
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
	if u.Disabled {
		writeErr(w, 403, "this account is disabled; ask an administrator")
		return
	}
	tok, err := s.Store.NewSession(u.ID, 30*24*time.Hour)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	s.Store.TouchLogin(u.ID)
	s.Store.Audit(u.Username, "login", clientIP(r))
	u.Perms = u.Effective()
	writeJSON(w, 200, map[string]any{"token": tok, "user": u})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	s.Store.DeleteSession(bearerToken(r))
	w.WriteHeader(204)
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)
	u.Perms = u.Effective()
	writeJSON(w, 200, u)
}

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
	perms := currentUser(r).Effective()
	for _, c := range cams {
		if !perms.CanSee(c.ID) {
			continue
		}
		n, b, o, _ := s.Store.RecordingStats(c.ID)
		stats = append(stats, camStat{c.ID, n, b, o})
	}
	// Average disk write rate over the last 10 minutes of indexed footage.
	const window = 10 * time.Minute
	written, _ := s.Store.BytesWrittenSince(time.Now().Add(-window).UnixMilli())
	writeJSON(w, 200, map[string]any{
		"version": Version, "server_time": time.Now().UnixMilli(), "disk": du, "recordings": stats,
		"write_bps": float64(written) / window.Seconds(), "uptime_s": int64(time.Since(startTime).Seconds()),
	})
}

var startTime = time.Now()

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
	perms := currentUser(r).Effective()
	out := make([]cameraView, 0, len(cams))
	for _, c := range cams {
		if !perms.CanSee(c.ID) {
			continue
		}
		c.OnvifPass = ""
		if !admin {
			c.MainURL, c.SubURL = redact(c.MainURL), redact(c.SubURL)
		}
		out = append(out, cameraView{c, s.Cams.Status(c.ID)})
	}
	writeJSON(w, 200, out)
}

// redact hides the login in a stream URL from non-admin users.
func redact(u string) string {
	sch := strings.Index(u, "://")
	if sch < 0 {
		return u
	}
	rest := u[sch+3:]
	authority := rest
	if i := strings.IndexAny(rest, "/?#"); i >= 0 {
		authority = rest[:i]
	}
	at := strings.LastIndex(authority, "@") // passwords may contain '@'
	if at < 0 {
		return u
	}
	return u[:sch+3] + "***@" + rest[at+1:]
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
	if c.RecordMode != "continuous" && c.RecordMode != "motion" {
		c.RecordMode = "off"
	}
	if c.RecordSchedule == nil {
		c.RecordSchedule = []store.ScheduleRule{}
	}
	if len(c.RecordSchedule) > 20 {
		return errors.New("a camera can have at most 20 schedule rules")
	}
	for _, r := range c.RecordSchedule {
		if err := r.Validate(); err != nil {
			return err
		}
	}
	if c.UsesMode("motion") {
		c.Motion = true // motion-only recording needs the detector
	}
	if c.MotionSensitivity <= 0 {
		c.MotionSensitivity = 50
	}
	c.MotionSensitivity = min(c.MotionSensitivity, 100)
	if strings.TrimSpace(c.MotionMask) != "" {
		c.MotionMask = motion.ParseCells(c.MotionMask).String()
	} else {
		c.MotionMask = ""
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
	s.audit(r, "camera.create", c.Name)
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
	s.audit(r, "camera.update", c.Name)
	c.OnvifPass = ""
	writeJSON(w, 200, c)
}

func (s *Server) deleteCamera(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	old, err := s.Store.Camera(id)
	if err != nil {
		writeErr(w, 404, "camera not found")
		return
	}
	s.Cams.Stop(id)
	s.ptz.invalidate(id)
	if err := s.Store.DeleteCamera(id); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	s.audit(r, "camera.delete", old.Name)
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
	if t := queryInt(r, "t", 0); t > 0 {
		s.recordedFrame(w, r, id, t)
		return
	}
	stream := r.URL.Query().Get("stream")
	if stream == "" {
		stream = "sub"
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	img, err := s.LiveJPEG(ctx, id, stream)
	if err != nil {
		writeErr(w, 504, err.Error())
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(img)
}

// hubInput makes ffmpeg start quickly on a hub stream: the hub begins with a
// keyframe, so half a second of probing is enough (the default waits ~5 s).
var hubInput = [4]string{"-probesize", "1000000", "-analyzeduration", "500000"}

// LiveJPEG grabs the next decodable frame of a camera's live stream as a JPEG.
func (s *Server) LiveJPEG(ctx context.Context, id int64, stream string) ([]byte, error) {
	hub := s.Cams.Hub(id, stream)
	if hub == nil {
		return nil, errors.New("camera not running")
	}
	cmd := exec.CommandContext(ctx, s.FFmpeg, "-hide_banner", "-loglevel", "error", hubInput[0], hubInput[1], hubInput[2], hubInput[3],
		"-f", "mpegts", "-i", "pipe:0", "-frames:v", "1", "-vf", "scale='min(640,iw)':-2", "-q:v", "4", "-f", "image2", "-c:v", "mjpeg", "pipe:1")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
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
		return nil, errors.New("no frame available")
	}
	return img, nil
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
