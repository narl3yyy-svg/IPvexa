package notify

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// Register mounts the ntfy-compatible endpoints:
//
//	GET /{topic}/json   newline-delimited JSON stream (?poll=1 to return at once, ?since=)
//	GET /{topic}/sse    server-sent events
//	GET /{topic}/auth   credential check used by the ntfy app
//	GET /v1/file/{name}    notification images (unguessable names, expire after a day)
//	GET /v1/health
func (n *Notifier) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /{topic}/json", func(w http.ResponseWriter, r *http.Request) { n.subscribe(w, r, false) })
	mux.HandleFunc("GET /{topic}/sse", func(w http.ResponseWriter, r *http.Request) { n.subscribe(w, r, true) })
	mux.HandleFunc("GET /{topic}/auth", func(w http.ResponseWriter, r *http.Request) {
		if !n.authorized(w, r) {
			return
		}
		writeJSON(w, map[string]bool{"success": true})
	})
	mux.HandleFunc("GET /v1/file/{name}", n.serveFile)
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]bool{"healthy": true})
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

// authorized checks the topic and the subscriber's login. ntfy clients send
// Basic auth (username/password), or ?auth= with a base64 Authorization header.
func (n *Notifier) authorized(w http.ResponseWriter, r *http.Request) bool {
	if r.PathValue("topic") != n.Topic() {
		http.Error(w, `{"code":40401,"http":404,"error":"topic not found"}`, http.StatusNotFound)
		return false
	}
	if n.Auth == nil || !n.Auth(r) {
		w.Header().Set("WWW-Authenticate", `Basic realm="IPvexa"`)
		http.Error(w, `{"code":40101,"http":401,"error":"unauthorized"}`, http.StatusUnauthorized)
		return false
	}
	return true
}

// absolute turns server-relative links into full URLs for this subscriber.
func absolute(r *http.Request, m Message) Message {
	base := "http://" + r.Host
	if r.TLS != nil {
		base = "https://" + r.Host
	}
	if strings.HasPrefix(m.Click, "/") {
		m.Click = base + m.Click
	}
	if m.Attachment != nil && strings.HasPrefix(m.Attachment.URL, "/") {
		a := *m.Attachment
		a.URL = base + a.URL
		m.Attachment = &a
	}
	return m
}

func (n *Notifier) subscribe(w http.ResponseWriter, r *http.Request, sse bool) {
	if !n.authorized(w, r) {
		return
	}
	topic := n.Topic()
	q := r.URL.Query()
	since := q.Get("since")
	poll := q.Get("poll") == "1" || q.Has("poll")
	if poll && since == "" {
		since = "all"
	}
	if sse {
		w.Header().Set("Content-Type", "text/event-stream")
	} else {
		w.Header().Set("Content-Type", "application/x-ndjson; charset=utf-8")
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	fl, _ := w.(http.Flusher)
	send := func(m Message) error {
		b, _ := json.Marshal(absolute(r, m))
		var err error
		if sse {
			if m.Event == "message" {
				_, err = fmt.Fprintf(w, "id: %s\ndata: %s\n\n", m.ID, b)
			} else {
				_, err = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", m.Event, b)
			}
		} else {
			_, err = fmt.Fprintf(w, "%s\n", b)
		}
		if fl != nil {
			fl.Flush()
		}
		return err
	}
	if poll {
		for _, m := range n.History(since) {
			send(m)
		}
		return
	}
	c := make(chan Message, 32)
	n.mu.Lock()
	n.subs[c] = struct{}{}
	n.mu.Unlock()
	defer func() {
		n.mu.Lock()
		delete(n.subs, c)
		n.mu.Unlock()
	}()
	if send(Message{ID: randomID(6), Time: time.Now().Unix(), Event: "open", Topic: topic}) != nil {
		return
	}
	for _, m := range n.History(since) {
		if send(m) != nil {
			return
		}
	}
	keep := time.NewTicker(45 * time.Second)
	defer keep.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case m := <-c:
			if send(m) != nil {
				return
			}
		case <-keep.C:
			if send(Message{ID: randomID(6), Time: time.Now().Unix(), Event: "keepalive", Topic: topic}) != nil {
				return
			}
		}
	}
}

func (n *Notifier) serveFile(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSuffix(r.PathValue("name"), ".jpg")
	n.mu.Lock()
	f, ok := n.files[id]
	n.mu.Unlock()
	if !ok || time.Now().After(f.expires) {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	w.Write(f.data)
}

// CameraState is what the watcher needs to know about a camera.
type CameraState struct {
	ID      int64
	Name    string
	Enabled bool
	Online  bool
	Error   string
}

// Watch raises offline/online and disk_low events until ctx ends. cameras returns
// the current camera states; freePct the recording disk's free space (percent).
func (n *Notifier) Watch(ctx context.Context, cameras func() []CameraState, freePct func() float64, minFreePct func() float64) {
	type track struct {
		online   bool
		offSince time.Time
		notified bool // offline alert sent for the current outage
	}
	seen := map[int64]*track{}
	diskWarned := time.Time{}
	tick := time.NewTicker(10 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		now := time.Now()
		for _, c := range cameras() {
			if !c.Enabled {
				delete(seen, c.ID)
				continue
			}
			t, ok := seen[c.ID]
			if !ok {
				// First sight: remember the state without alerting (e.g. after a restart).
				seen[c.ID] = &track{online: c.Online, offSince: now, notified: !c.Online}
				continue
			}
			switch {
			case !c.Online && t.online:
				t.online, t.offSince = false, now
			case !c.Online && !t.notified && now.Sub(t.offSince) >= 30*time.Second:
				// Only outages that last 30 s are reported, so brief reconnects stay quiet.
				t.notified = true
				n.Handle(Event{Trigger: "offline", CameraID: c.ID, Camera: c.Name, Time: t.offSince, Detail: c.Error})
			case c.Online && !t.online:
				if t.notified {
					n.Handle(Event{Trigger: "online", CameraID: c.ID, Camera: c.Name, Time: now})
				}
				t.online, t.notified = true, false
			}
		}
		if freePct != nil && minFreePct != nil {
			if free := freePct(); free < minFreePct()+3 && now.Sub(diskWarned) > 6*time.Hour {
				diskWarned = now
				n.Handle(Event{Trigger: "disk_low", Time: now,
					Detail: fmt.Sprintf("Only %.0f%% of the recording disk is free. The oldest footage is being deleted to make room.", free)})
			}
		}
	}
}
