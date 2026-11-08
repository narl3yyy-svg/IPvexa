package notify

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"ipvexa/internal/store"
)

func at(day time.Weekday, hh, mm int) time.Time {
	// 2026-11-01 is a Sunday.
	return time.Date(2026, 11, 1+int(day), hh, mm, 0, 0, time.Local)
}

func TestSchedule(t *testing.T) {
	night := Rule{Trigger: "motion", From: "22:00", To: "06:00", Days: []int{5}} // Friday nights
	if err := night.Normalize(); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		t    time.Time
		want bool
	}{
		{at(time.Friday, 23, 0), true},
		{at(time.Saturday, 5, 59), true}, // Friday's window continues past midnight
		{at(time.Saturday, 6, 0), false},
		{at(time.Saturday, 23, 0), false},
		{at(time.Friday, 5, 0), false}, // Thursday night is not scheduled
		{at(time.Friday, 12, 0), false},
	}
	for _, c := range cases {
		if got := night.Active(c.t); got != c.want {
			t.Errorf("Active(%s) = %v, want %v", c.t.Format("Mon 15:04"), got, c.want)
		}
	}
	day := Rule{Trigger: "motion", From: "08:00", To: "17:30"}
	day.Normalize()
	if !day.Active(at(time.Tuesday, 8, 0)) || day.Active(at(time.Tuesday, 17, 30)) {
		t.Error("day window bounds")
	}
	bad := []Rule{{Trigger: "nope"}, {Trigger: "motion", From: "25:00", To: "01:00"}, {Trigger: "motion", From: "08:00"},
		{Trigger: "motion", From: "08:00", To: "08:00"}, {Trigger: "motion", Webhook: "ftp://x"}}
	for _, r := range bad {
		if r.Normalize() == nil {
			t.Errorf("rule %+v should be rejected", r)
		}
	}
}

func newNotifier(t *testing.T) *Notifier {
	db, err := store.Open(filepath.Join(t.TempDir(), "n.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return New(db)
}

func TestRulesAndCooldown(t *testing.T) {
	n := newNotifier(t)
	err := n.SetRules([]Rule{
		{Name: "Yard", Enabled: true, Trigger: "motion", Cameras: []int64{2}, Cooldown: 60, Notify: true},
		{Name: "Off", Enabled: false, Trigger: "motion", Notify: true},
	})
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Now()
	n.Handle(Event{Trigger: "motion", CameraID: 2, Camera: "Yard", Time: t0})
	n.Handle(Event{Trigger: "motion", CameraID: 2, Camera: "Yard", Time: t0.Add(30 * time.Second)}) // cooldown
	n.Handle(Event{Trigger: "motion", CameraID: 3, Camera: "Door", Time: t0})                       // other camera
	n.Handle(Event{Trigger: "motion", CameraID: 2, Camera: "Yard", Time: t0.Add(61 * time.Second)})
	deadline := time.Now().Add(2 * time.Second)
	for len(n.History("all")) < 2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	h := n.History("all")
	if len(h) != 2 {
		t.Fatalf("got %d messages, want 2", len(h))
	}
	if !strings.Contains(h[0].Title, "Yard") || h[0].Topic != n.Topic() || h[0].Click == "" {
		t.Errorf("message = %+v", h[0])
	}
	if got := n.History(h[0].ID); len(got) != 1 || got[0].ID != h[1].ID {
		t.Error("since=<id> should return only newer messages")
	}
}

func TestFeed(t *testing.T) {
	n := newNotifier(t)
	n.Auth = func(r *http.Request) bool { u, p, ok := r.BasicAuth(); return ok && u == "admin" && p == "pw" }
	mux := http.NewServeMux()
	n.Register(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	topic := n.Topic()

	get := func(path string, auth bool) *http.Response {
		req, _ := http.NewRequest("GET", srv.URL+path, nil)
		if auth {
			req.SetBasicAuth("admin", "pw")
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	if r := get("/"+topic+"/json?poll=1", false); r.StatusCode != 401 {
		t.Errorf("no login: %d", r.StatusCode)
	}
	if r := get("/wrong-topic/json?poll=1", true); r.StatusCode != 404 {
		t.Errorf("wrong topic: %d", r.StatusCode)
	}
	if r := get("/"+topic+"/auth", true); r.StatusCode != 200 {
		t.Errorf("auth check: %d", r.StatusCode)
	}

	// Stream: open event first, then a published message with absolute links.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", srv.URL+"/"+topic+"/json", nil)
	req.SetBasicAuth("admin", "pw")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	sc := bufio.NewScanner(resp.Body)
	var first Message
	if !sc.Scan() || json.Unmarshal(sc.Bytes(), &first) != nil || first.Event != "open" {
		t.Fatalf("first line should be the open event: %q", sc.Text())
	}
	att := n.storeFile([]byte{0xff, 0xd8, 0xff}, "x.jpg")
	n.Publish(Message{Title: "hello", Click: "/web/#camera=1", Attachment: att})
	var m Message
	if !sc.Scan() || json.Unmarshal(sc.Bytes(), &m) != nil {
		t.Fatal("no message received")
	}
	if m.Title != "hello" || !strings.HasPrefix(m.Click, srv.URL) || !strings.HasPrefix(m.Attachment.URL, srv.URL) {
		t.Errorf("message = %+v", m)
	}
	if r := get(strings.TrimPrefix(m.Attachment.URL, srv.URL), false); r.StatusCode != 200 || r.Header.Get("Content-Type") != "image/jpeg" {
		t.Errorf("attachment: %d", r.StatusCode)
	}
	if r := get("/v1/file/nope.jpg", false); r.StatusCode != 404 {
		t.Errorf("unknown attachment: %d", r.StatusCode)
	}
}
