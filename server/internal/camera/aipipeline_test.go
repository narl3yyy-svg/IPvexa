package camera

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"ipvexa/internal/ai"
	"ipvexa/internal/store"
)

// TestAIPipeline runs the whole motion analyser (ffmpeg, motion detector, object
// detector) on a video played in real time, when the detector and a video are given:
//
//	IPVEXA_AI_DIR=/var/lib/ipvexa/ai IPVEXA_AI_VIDEO=walk.ts IPVEXA_AI_WANT=people IPVEXA_AI_EXPECT=person \
//	  go test ./internal/camera -run AIPipeline -v
//
// IPVEXA_AI_EXPECT is the objects the first event should have, or "none" when no
// event is expected.
func TestAIPipeline(t *testing.T) {
	dir, video := os.Getenv("IPVEXA_AI_DIR"), os.Getenv("IPVEXA_AI_VIDEO")
	if dir == "" || video == "" {
		t.Skip("set IPVEXA_AI_DIR and IPVEXA_AI_VIDEO")
	}
	eng := ai.Open(dir)
	if !eng.Available() {
		t.Fatal(eng.Status().Error)
	}
	db, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	var mu sync.Mutex
	var events []store.Event
	m := &Manager{Store: db, FFmpeg: "ffmpeg", AI: eng, OnEvent: func(e store.Event, started bool) {
		if !started {
			mu.Lock()
			events = append(events, e)
			mu.Unlock()
		}
	}}
	hub := NewHub()
	r := &running{cam: store.Camera{ID: 1, Motion: true, MotionSensitivity: 50, MotionObjects: os.Getenv("IPVEXA_AI_WANT")},
		main: &Stream{Hub: hub}}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { m.runMotion(ctx, r); close(done) }()
	time.Sleep(500 * time.Millisecond) // let the analyser subscribe

	play := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-i", video, "-c", "copy", "-f", "mpegts", "pipe:1")
	play.Stdout = hub
	if err := play.Run(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(6 * time.Second) // let the last event end
	cancel()
	<-done

	mu.Lock()
	defer mu.Unlock()
	for _, e := range events {
		t.Logf("event %d–%d ms, objects %q", e.Start, e.End, e.Objects)
	}
	st := eng.Status()
	t.Logf("detector: %s, %d runs, %.0f ms each", st.Model, st.Runs, st.AvgMs)
	switch want := os.Getenv("IPVEXA_AI_EXPECT"); {
	case want == "none" && len(events) > 0:
		t.Errorf("expected no event, got %d", len(events))
	case want != "none" && want != "" && (len(events) == 0 || events[0].Objects != want):
		t.Errorf("expected an event with %q", want)
	}
}
