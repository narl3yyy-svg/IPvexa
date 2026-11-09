// Package notify turns camera events into phone notifications and webhooks.
//
// Alerts are published on an ntfy-compatible feed served by ipvexa-server itself:
// the ntfy Android app (or any ntfy client) subscribes to it over the LAN or a VPN,
// so no cloud service is involved. Rules decide what triggers an alert, where,
// when, and how often.
package notify

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"ipvexa/internal/store"
)

// Rule: when Trigger happens on one of Cameras (all when empty), during the
// schedule, at most once per Cooldown seconds per camera → do the actions.
type Rule struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Enabled  bool    `json:"enabled"`
	Trigger  string  `json:"trigger"` // motion | offline | online | disk_low
	Cameras  []int64 `json:"cameras"`
	Days     []int   `json:"days"` // 0 = Sunday … 6; empty = every day
	From     string  `json:"from"` // "HH:MM"; empty = all day. To < From spans midnight.
	To       string  `json:"to"`
	Cooldown int     `json:"cooldown"` // seconds, default 60
	Priority int     `json:"priority"` // ntfy priority 1 (min) … 5 (urgent), default 3
	Notify   bool    `json:"notify"`   // send to the phone feed
	Webhook  string  `json:"webhook"`  // POST JSON here (e.g. Home Assistant), optional
	Bookmark bool    `json:"bookmark"` // add a bookmark at the event
}

var Triggers = []string{"motion", "offline", "online", "disk_low"}

// Normalize fills defaults and validates a rule.
func (r *Rule) Normalize() error {
	r.Name = strings.TrimSpace(r.Name)
	if !slices.Contains(Triggers, r.Trigger) {
		return fmt.Errorf("unknown trigger %q", r.Trigger)
	}
	if r.Name == "" {
		r.Name = r.Trigger
	}
	if r.ID == "" {
		r.ID = randomID(6)
	}
	if r.Cooldown <= 0 {
		r.Cooldown = 60
	}
	if r.Priority < 1 || r.Priority > 5 {
		r.Priority = 3
	}
	for _, t := range []string{r.From, r.To} {
		if t != "" {
			if _, err := parseClock(t); err != nil {
				return fmt.Errorf("times must look like 22:30")
			}
		}
	}
	if (r.From == "") != (r.To == "") {
		return fmt.Errorf("set both a start and an end time, or neither")
	}
	if r.From != "" && r.From == r.To {
		return fmt.Errorf("the start and end times are the same")
	}
	r.Webhook = strings.TrimSpace(r.Webhook)
	if r.Webhook != "" && !strings.HasPrefix(r.Webhook, "http://") && !strings.HasPrefix(r.Webhook, "https://") {
		return fmt.Errorf("the webhook must be an http:// or https:// address")
	}
	if r.Cameras == nil {
		r.Cameras = []int64{}
	}
	if r.Days == nil {
		r.Days = []int{}
	}
	return nil
}

func parseClock(s string) (int, error) {
	t, err := time.Parse("15:04", s)
	if err != nil {
		return 0, err
	}
	return t.Hour()*60 + t.Minute(), nil
}

// Active reports whether the rule's schedule includes time t. An overnight window
// (e.g. 22:00–06:00) belongs to the day it starts on.
func (r *Rule) Active(t time.Time) bool {
	dayOK := func(d time.Weekday) bool { return len(r.Days) == 0 || slices.Contains(r.Days, int(d)) }
	if r.From == "" {
		return dayOK(t.Weekday())
	}
	from, _ := parseClock(r.From)
	to, _ := parseClock(r.To)
	now := t.Hour()*60 + t.Minute()
	switch {
	case from < to:
		return dayOK(t.Weekday()) && now >= from && now < to
	case now >= from:
		return dayOK(t.Weekday())
	case now < to:
		return dayOK(t.Add(-24 * time.Hour).Weekday())
	}
	return false
}

func (r *Rule) matchesCamera(id int64) bool {
	return len(r.Cameras) == 0 || slices.Contains(r.Cameras, id)
}

// Message is an ntfy message. Paths in Click and Attachment.URL are server-relative
// and made absolute for each subscriber.
type Message struct {
	ID         string      `json:"id"`
	Time       int64       `json:"time"`
	Expires    int64       `json:"expires,omitempty"`
	Event      string      `json:"event"`
	Topic      string      `json:"topic"`
	Title      string      `json:"title,omitempty"`
	Message    string      `json:"message,omitempty"`
	Priority   int         `json:"priority,omitempty"`
	Tags       []string    `json:"tags,omitempty"`
	Click      string      `json:"click,omitempty"`
	Attachment *Attachment `json:"attachment,omitempty"`
}

type Attachment struct {
	Name    string `json:"name"`
	Type    string `json:"type"`
	Size    int64  `json:"size"`
	Expires int64  `json:"expires"`
	URL     string `json:"url"`
}

// Event describes something a rule can react to.
type Event struct {
	Trigger  string
	CameraID int64 // 0 for server-wide events (disk_low)
	Camera   string
	Time     time.Time
	Detail   string
}

const (
	historySize = 200
	fileTTL     = 24 * time.Hour
	maxFiles    = 300
)

type file struct {
	data    []byte
	expires time.Time
}

// Notifier evaluates rules and publishes messages. Create with New.
type Notifier struct {
	Store *store.Store
	// Snapshot returns a JPEG of the camera right now (optional).
	Snapshot func(ctx context.Context, camID int64) ([]byte, error)
	// Auth checks a subscriber's credentials (Basic auth or a session token).
	Auth func(r *http.Request) bool

	mu       sync.Mutex
	topicMu  sync.Mutex
	subs     map[chan Message]struct{}
	history  []Message
	files    map[string]file
	lastFire map[string]time.Time
	http     *http.Client
}

func New(st *store.Store) *Notifier {
	return &Notifier{Store: st, subs: map[chan Message]struct{}{}, files: map[string]file{},
		lastFire: map[string]time.Time{}, http: &http.Client{Timeout: 10 * time.Second}}
}

func randomID(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// Topic is the feed name phones subscribe to; created on first use.
func (n *Notifier) Topic() string {
	// Serialised so concurrent alerts can't each create a different name.
	n.topicMu.Lock()
	defer n.topicMu.Unlock()
	t, _ := n.Store.Setting("ntfy_topic")
	if t == "" {
		t = "ipvexa-" + randomID(4)
		n.Store.SetSetting("ntfy_topic", t)
	}
	return t
}

func (n *Notifier) Rules() []Rule {
	rules := []Rule{}
	n.Store.SettingJSON("rules", &rules)
	return rules
}

func (n *Notifier) SetRules(rules []Rule) error {
	for i := range rules {
		if err := rules[i].Normalize(); err != nil {
			return fmt.Errorf("rule %q: %w", rules[i].Name, err)
		}
	}
	return n.Store.SetSettingJSON("rules", rules)
}

// Handle runs every enabled rule that matches the event.
func (n *Notifier) Handle(e Event) {
	if e.Time.IsZero() {
		e.Time = time.Now()
	}
	for _, r := range n.Rules() {
		if !r.Enabled || r.Trigger != e.Trigger || !r.Active(e.Time) || (e.CameraID != 0 && !r.matchesCamera(e.CameraID)) {
			continue
		}
		key := r.ID + "/" + strconv.FormatInt(e.CameraID, 10)
		n.mu.Lock()
		if last, ok := n.lastFire[key]; ok && e.Time.Sub(last) < time.Duration(r.Cooldown)*time.Second {
			n.mu.Unlock()
			continue
		}
		n.lastFire[key] = e.Time
		n.mu.Unlock()
		go n.fire(r, e)
	}
}

func describe(e Event) (title, body string, tags []string) {
	at := e.Time.Format("15:04:05")
	switch e.Trigger {
	case "motion":
		return "Motion · " + e.Camera, "Motion detected at " + at, []string{"rotating_light"}
	case "offline":
		body := e.Camera + " stopped sending video at " + at
		if e.Detail != "" {
			body += ". " + e.Detail
		}
		return "Camera offline · " + e.Camera, body, []string{"warning"}
	case "online":
		return "Camera back online · " + e.Camera, e.Camera + " is sending video again (" + at + ")", []string{"white_check_mark"}
	case "disk_low":
		return "Recording disk almost full", e.Detail, []string{"floppy_disk"}
	}
	return e.Trigger, at, nil
}

func (n *Notifier) fire(r Rule, e Event) {
	title, body, tags := describe(e)
	if r.Bookmark && e.CameraID != 0 {
		ms := e.Time.UnixMilli()
		n.Store.AddEvent(&store.Event{CameraID: e.CameraID, Kind: "bookmark", Start: ms - 5000, End: ms + 10000,
			Note: "Alert: " + r.Name, Author: "rules"})
	}
	if r.Notify {
		msg := Message{Title: title, Message: body, Priority: r.Priority, Tags: tags}
		if e.CameraID != 0 {
			msg.Click = fmt.Sprintf("/web/#camera=%d&t=%d", e.CameraID, e.Time.Add(-5*time.Second).UnixMilli())
			if e.Trigger == "motion" && n.Snapshot != nil {
				ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
				img, err := n.Snapshot(ctx, e.CameraID)
				cancel()
				if err == nil && len(img) > 0 {
					msg.Attachment = n.storeFile(img, fmt.Sprintf("%s-%s.jpg", strings.ReplaceAll(e.Camera, " ", "_"), e.Time.Format("150405")))
				}
			}
		}
		n.Publish(msg)
	}
	if r.Webhook != "" {
		payload, _ := json.Marshal(map[string]any{"rule": r.Name, "trigger": e.Trigger, "camera_id": e.CameraID,
			"camera": e.Camera, "time": e.Time.UnixMilli(), "title": title, "message": body})
		resp, err := n.http.Post(r.Webhook, "application/json", bytes.NewReader(payload))
		if err != nil {
			slog.Warn("webhook failed", "rule", r.Name, "err", err)
		} else {
			resp.Body.Close()
		}
	}
}

func (n *Notifier) storeFile(data []byte, name string) *Attachment {
	id := randomID(16)
	exp := time.Now().Add(fileTTL)
	n.mu.Lock()
	now := time.Now()
	for k, f := range n.files {
		if now.After(f.expires) || len(n.files) >= maxFiles {
			delete(n.files, k)
		}
	}
	n.files[id] = file{data: data, expires: exp}
	n.mu.Unlock()
	return &Attachment{Name: name, Type: "image/jpeg", Size: int64(len(data)), Expires: exp.Unix(), URL: "/v1/file/" + id + ".jpg"}
}

// Publish sends a message to every subscriber and keeps it for polling clients.
func (n *Notifier) Publish(m Message) Message {
	m.ID = randomID(6)
	m.Time = time.Now().Unix()
	m.Expires = time.Now().Add(12 * time.Hour).Unix()
	m.Event = "message"
	m.Topic = n.Topic()
	n.mu.Lock()
	n.history = append(n.history, m)
	if len(n.history) > historySize {
		n.history = n.history[len(n.history)-historySize:]
	}
	for c := range n.subs {
		select {
		case c <- m:
		default: // slow subscriber: it will catch up by polling
		}
	}
	n.mu.Unlock()
	return m
}

// History returns stored messages newer than since (an id, unix seconds, or "all").
func (n *Notifier) History(since string) []Message {
	n.mu.Lock()
	defer n.mu.Unlock()
	if since == "" {
		return nil
	}
	if since == "all" {
		return slices.Clone(n.history)
	}
	if ts, err := strconv.ParseInt(since, 10, 64); err == nil {
		var out []Message
		for _, m := range n.history {
			if m.Time >= ts {
				out = append(out, m)
			}
		}
		return out
	}
	for i, m := range n.history {
		if m.ID == since {
			return slices.Clone(n.history[i+1:])
		}
	}
	return slices.Clone(n.history) // unknown id: send everything we have
}
