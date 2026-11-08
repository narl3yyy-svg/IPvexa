package storage

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"ipvexa/internal/store"
)

// Motion-only cameras keep footage within 10 s of motion or a bookmark; the rest goes.
func TestMotionOnlySweep(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "r.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	cam := store.Camera{Name: "yard", MainURL: "demo://pattern", RecordMode: "motion", Enabled: true}
	if err := db.CreateCamera(&cam); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	base := now.Add(-30 * time.Minute).UnixMilli()
	minute := int64(60000)
	// Ten one-minute segments starting 30 minutes ago, plus one that is too recent to touch.
	var paths []string
	add := func(start int64) {
		rel := filepath.Join("1", "main", "seg", time.UnixMilli(start).Format("150405")+".mp4")
		p := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte("x"), 0o644)
		if err := db.AddSegment(&store.Segment{CameraID: cam.ID, Stream: "main", Path: rel, Start: start, End: start + minute, Size: 1}); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}
	for i := 0; i < 10; i++ {
		add(base + int64(i)*minute)
	}
	add(now.Add(-time.Minute).UnixMilli()) // within the grace period

	// Motion inside segment 2; a bookmark 5 s before segment 6 starts (pad reaches into it).
	db.AddEvent(&store.Event{CameraID: cam.ID, Kind: "motion", Start: base + 2*minute + 20000, End: base + 2*minute + 30000})
	db.AddEvent(&store.Event{CameraID: cam.ID, Kind: "bookmark", Start: base + 6*minute - 5000, End: base + 6*minute - 5000})

	r := &Retention{Store: db, RecRoot: dir}
	r.Sweep()

	keep := map[int]bool{2: true, 5: true, 6: true, 10: true}
	for i, p := range paths {
		_, err := os.Stat(p)
		if exists := err == nil; exists != keep[i] {
			t.Errorf("segment %d: exists=%v, want %v", i, exists, keep[i])
		}
	}
	left, _ := db.Segments(cam.ID, "main", 0, now.Add(time.Hour).UnixMilli())
	if len(left) != len(keep) {
		t.Errorf("%d segments indexed, want %d", len(left), len(keep))
	}
}
