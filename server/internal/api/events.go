package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"ipvexa/internal/motion"
	"ipvexa/internal/store"
)

// ---------- events (motion, bookmarks) ----------

// listEvents: GET /api/events?from=&to=&camera=1,2&kind=motion&cells=<hex>&limit=&newest=1
// cells limits motion events to those that moved inside the given area (smart search).
func (s *Server) listEvents(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)
	p := u.Effective()
	if !p.Playback {
		writeErr(w, 403, "your account is not allowed to view recordings")
		return
	}
	q := r.URL.Query()
	eq := store.EventQuery{From: queryInt(r, "from", 0), To: queryInt(r, "to", 0), Kind: q.Get("kind"),
		Limit: int(queryInt(r, "limit", 500)), Newest: q.Get("newest") == "1"}
	if eq.Kind != "" && eq.Kind != "motion" && eq.Kind != "bookmark" {
		writeErr(w, 400, "kind must be motion or bookmark")
		return
	}
	cams, err := s.Store.Cameras()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	want := map[int64]bool{}
	if c := q.Get("camera"); c != "" {
		for _, f := range strings.Split(c, ",") {
			if id, err := strconv.ParseInt(strings.TrimSpace(f), 10, 64); err == nil {
				want[id] = true
			}
		}
	}
	eq.Cameras = []int64{}
	for _, c := range cams {
		if p.CanSee(c.ID) && (len(want) == 0 || want[c.ID]) {
			eq.Cameras = append(eq.Cameras, c.ID)
		}
	}
	evs, err := s.Store.Events(eq)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	if area := q.Get("cells"); area != "" {
		a := motion.ParseCells(area)
		out := evs[:0]
		for _, e := range evs {
			if e.Kind == "motion" && motion.ParseCells(e.Cells).Overlaps(a) {
				out = append(out, e)
			}
		}
		evs = out
	}
	writeJSON(w, 200, evs)
}

func (s *Server) addBookmark(w http.ResponseWriter, r *http.Request) {
	id, _ := pathID(r)
	var req struct {
		Start, End int64
		Note       string
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 16384)).Decode(&req); err != nil || req.Start <= 0 {
		writeErr(w, 400, "bad request")
		return
	}
	if req.End < req.Start {
		req.End = req.Start
	}
	e := store.Event{CameraID: id, Kind: "bookmark", Start: req.Start, End: req.End,
		Note: strings.TrimSpace(req.Note), Author: currentUser(r).Username}
	if len(e.Note) > 2000 {
		e.Note = e.Note[:2000]
	}
	if err := s.Store.AddEvent(&e); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 201, e)
}

// eventForEdit loads an event the current user may change: bookmarks by their
// author or an admin; motion events by an admin.
func (s *Server) eventForEdit(w http.ResponseWriter, r *http.Request) (store.Event, bool) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return store.Event{}, false
	}
	e, err := s.Store.EventByID(id)
	u := currentUser(r)
	if err != nil || !u.Effective().CanSee(e.CameraID) {
		writeErr(w, 404, "event not found")
		return e, false
	}
	if u.Role != "admin" && (e.Kind != "bookmark" || e.Author != u.Username) {
		writeErr(w, 403, "you can only change your own bookmarks")
		return e, false
	}
	return e, true
}

func (s *Server) updateEvent(w http.ResponseWriter, r *http.Request) {
	e, ok := s.eventForEdit(w, r)
	if !ok {
		return
	}
	var req struct{ Note string }
	if err := json.NewDecoder(io.LimitReader(r.Body, 16384)).Decode(&req); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
	if e.Kind != "bookmark" {
		writeErr(w, 400, "only bookmarks have notes")
		return
	}
	e.Note = strings.TrimSpace(req.Note)
	if err := s.Store.UpdateEventNote(e.ID, e.Note); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, e)
}

func (s *Server) deleteEvent(w http.ResponseWriter, r *http.Request) {
	e, ok := s.eventForEdit(w, r)
	if !ok {
		return
	}
	if err := s.Store.DeleteEvent(e.ID); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	w.WriteHeader(204)
}

// thumbPath is where an event's thumbnail is kept: <ThumbDir>/<day>/<id>.jpg, so
// retention can remove whole days.
func (s *Server) thumbPath(e store.Event) string {
	return filepath.Join(s.ThumbDir, time.UnixMilli(e.Start).Format("2006-01-02"), strconv.FormatInt(e.ID, 10)+".jpg")
}

// SaveThumb stores a live snapshot as the event's thumbnail (called when motion starts).
func (s *Server) SaveThumb(e store.Event) {
	if s.ThumbDir == "" || e.ID == 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	img, err := s.LiveJPEG(ctx, e.CameraID, "sub")
	if err != nil {
		slog.Debug("event thumbnail", "event", e.ID, "err", err)
		return
	}
	p := s.thumbPath(e)
	if err := os.MkdirAll(filepath.Dir(p), 0o750); err == nil {
		os.WriteFile(p, img, 0o640)
	}
}

// eventThumb serves an event's thumbnail, or a frame from the recording if there is none.
func (s *Server) eventThumb(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	e, err := s.Store.EventByID(id)
	p := currentUser(r).Effective()
	if err != nil || !p.CanSee(e.CameraID) {
		writeErr(w, 404, "event not found")
		return
	}
	if !p.Playback {
		writeErr(w, 403, "your account is not allowed to view recordings")
		return
	}
	if s.ThumbDir != "" {
		if img, err := os.ReadFile(s.thumbPath(e)); err == nil {
			w.Header().Set("Content-Type", "image/jpeg")
			w.Header().Set("Cache-Control", "private, max-age=86400")
			w.Write(img)
			return
		}
	}
	s.recordedFrame(w, r, e.CameraID, e.Start+1000)
}

// recordedFrame serves a JPEG of the recording at time t (event thumbnails).
func (s *Server) recordedFrame(w http.ResponseWriter, r *http.Request, id, t int64) {
	if !currentUser(r).Effective().Playback {
		writeErr(w, 403, "your account is not allowed to view recordings")
		return
	}
	var seg *store.Segment
	for _, stream := range []string{"sub", "main"} {
		segs, err := s.Store.Segments(id, stream, t, t+1)
		if err == nil && len(segs) > 0 {
			seg = &segs[0]
			break
		}
	}
	path, start := "", int64(0)
	if seg != nil {
		path, start = seg.File(s.RecRoot), seg.Start
	} else if p, st, ok := s.Cams.OpenSegment(id, "main"); ok && st <= t {
		path, start = p, st
	} else {
		writeErr(w, 404, "no recording at this time")
		return
	}
	width := min(max(queryInt(r, "w", 320), 64), 1280)
	cmd := exec.CommandContext(r.Context(), s.FFmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
		"-ss", fmt.Sprintf("%.3f", float64(t-start)/1000), "-i", path,
		"-frames:v", "1", "-vf", fmt.Sprintf("scale='min(%d,iw)':-2", width), "-q:v", "5",
		"-f", "image2", "-c:v", "mjpeg", "pipe:1")
	cmd.WaitDelay = 2 * time.Second
	img, err := cmd.Output()
	if err != nil || len(img) == 0 {
		writeErr(w, 404, "no frame at this time")
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	if seg != nil {
		w.Header().Set("Cache-Control", "private, max-age=86400") // recorded frames don't change
	}
	w.Write(img)
}

// ---------- audit ----------

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (s *Server) audit(r *http.Request, action, detail string) {
	s.Store.Audit(currentUser(r).Username, action, detail)
}

func (s *Server) auditLog(w http.ResponseWriter, r *http.Request) {
	entries, err := s.Store.AuditLog(int(queryInt(r, "limit", 500)))
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, entries)
}

// ---------- export ----------

const maxExport = 2 * time.Hour

var unsafeName = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// export streams recorded video between from and to (unix ms) as an MP4 download,
// copied without re-encoding (original quality).
func (s *Server) export(w http.ResponseWriter, r *http.Request) {
	id, _ := pathID(r)
	from, to := queryInt(r, "from", 0), queryInt(r, "to", 0)
	if from <= 0 || to <= from {
		writeErr(w, 400, "choose a start and end time")
		return
	}
	if time.Duration(to-from)*time.Millisecond > maxExport {
		writeErr(w, 400, "clips can be at most 2 hours long")
		return
	}
	stream := "main"
	if r.URL.Query().Get("stream") == "sub" {
		stream = "sub"
	}
	cam, err := s.Store.Camera(id)
	if err != nil {
		writeErr(w, 404, "camera not found")
		return
	}
	segs, err := s.Store.Segments(id, stream, from, to)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	type part struct {
		path       string
		start, end int64
	}
	var parts []part
	for _, g := range segs {
		parts = append(parts, part{g.File(s.RecRoot), g.Start, g.End})
	}
	if p, start, ok := s.Cams.OpenSegment(id, stream); ok && start < to {
		parts = append(parts, part{p, start, time.Now().UnixMilli()})
	}
	if len(parts) == 0 {
		writeErr(w, 404, "no recording in that time range")
		return
	}
	var list strings.Builder
	list.WriteString("ffconcat version 1.0\n")
	for _, p := range parts {
		fmt.Fprintf(&list, "file '%s'\n", strings.ReplaceAll(p.path, "'", `'\''`))
		if from > p.start {
			fmt.Fprintf(&list, "inpoint %.3f\n", float64(from-p.start)/1000)
		}
		if to < p.end {
			fmt.Fprintf(&list, "outpoint %.3f\n", float64(to-p.start)/1000)
		}
	}
	tmp, err := os.CreateTemp("", "ipvexa-export-*.ffconcat")
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	tmp.WriteString(list.String())
	tmp.Close()
	defer os.Remove(tmp.Name())

	cmd := exec.CommandContext(r.Context(), s.FFmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
		"-f", "concat", "-safe", "0", "-i", tmp.Name(),
		"-map", "0:v:0", "-map", "0:a?", "-c", "copy",
		"-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", "pipe:1")
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
	name := unsafeName.ReplaceAllString(cam.Name, "_") + "_" + time.UnixMilli(from).Format("2006-01-02_15-04-05") + ".mp4"
	w.Header().Set("Content-Type", "video/mp4")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	w.Header().Set("X-Ipvexa-Filename", name)
	w.WriteHeader(200)
	io.Copy(w, stdout)
	cmd.Wait()
	if msg := strings.TrimSpace(stderr.String()); msg != "" && r.Context().Err() == nil {
		slog.Warn("export ffmpeg", "camera", id, "msg", msg)
	}
	s.audit(r, "export", fmt.Sprintf("%s %s, %s", cam.Name, time.UnixMilli(from).Format(time.DateTime), time.Duration(to-from)*time.Millisecond))
}
