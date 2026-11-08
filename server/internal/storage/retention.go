// Package storage enforces retention: per-camera age limits, motion-only
// recording, an optional cap on total footage and a minimum of free disk space,
// always deleting the oldest footage first.
package storage

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"ipvexa/internal/store"
)

type Retention struct {
	Store      *store.Store
	RecRoot    string
	MinFreePct float64 // default minimum free disk space (percent); the app's setting overrides it
	Interval   time.Duration
	ThumbDir   string // event thumbnails, in one folder per day
}

func (r *Retention) Run(ctx context.Context) {
	if r.Interval == 0 {
		r.Interval = 5 * time.Minute
	}
	t := time.NewTicker(r.Interval)
	defer t.Stop()
	for {
		r.Sweep()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (r *Retention) Sweep() {
	cams, err := r.Store.Cameras()
	if err != nil {
		return
	}
	now := time.Now()
	for _, c := range cams {
		if c.RetentionDays <= 0 {
			continue
		}
		cutoff := now.Add(-time.Duration(c.RetentionDays) * 24 * time.Hour).UnixMilli()
		for {
			segs, err := r.Store.OldestSegments(c.ID, cutoff, 500)
			if err != nil || len(segs) == 0 {
				break
			}
			r.delete(segs)
		}
	}

	for _, c := range cams {
		if c.UsesMode("motion") {
			r.sweepMotionOnly(c, now)
		}
	}
	settings := r.Store.Server(r.MinFreePct)
	// Motion events are kept for EventDays, bookmarks forever; the audit log for a year.
	eventDays := time.Duration(settings.EventDays) * 24 * time.Hour
	r.Store.PurgeEvents(now.Add(-eventDays).UnixMilli())
	r.purgeThumbs(now.Add(-eventDays - 24*time.Hour))
	r.Store.PurgeAudit(now.Add(-365 * 24 * time.Hour).UnixMilli())

	// Storage cap: delete the oldest footage until the total fits.
	if settings.MaxStorageGB > 0 {
		limit := int64(settings.MaxStorageGB * (1 << 30))
		for i := 0; i < 1000; i++ {
			total, err := r.Store.TotalFootageBytes()
			if err != nil || total <= limit {
				break
			}
			segs, err := r.Store.OldestSegments(0, 0, 50)
			if err != nil || len(segs) == 0 {
				break
			}
			slog.Info("storage cap reached, deleting oldest footage", "total_gb", float64(total)/(1<<30), "segments", len(segs))
			r.delete(segs)
		}
	}

	// Disk-space guard: delete oldest footage across all cameras until enough is free.
	for i := 0; i < 1000; i++ {
		free, err := FreePct(r.RecRoot)
		if err != nil || free >= settings.MinFreePct {
			return
		}
		segs, err := r.Store.OldestSegments(0, 0, 50)
		if err != nil || len(segs) == 0 {
			return
		}
		slog.Warn("disk low, deleting oldest footage", "free_pct", free, "segments", len(segs))
		r.delete(segs)
	}
}

const (
	motionPad   = 10 * time.Second // footage kept before and after each event
	motionGrace = 2 * time.Minute  // leave recent footage alone (events may still be open)
)

// sweepMotionOnly deletes the last day's footage recorded in motion-only mode
// that has no motion event or bookmark within motionPad of it.
func (r *Retention) sweepMotionOnly(cam store.Camera, now time.Time) {
	camID := cam.ID
	to := now.Add(-motionGrace).UnixMilli()
	from := now.Add(-24 * time.Hour).UnixMilli()
	pad := motionPad.Milliseconds()
	evs, err := r.Store.Events(store.EventQuery{Cameras: []int64{camID}, From: from - pad, To: to + pad})
	if err != nil {
		return
	}
	keep := func(seg store.Segment) bool {
		for _, e := range evs {
			end := e.End
			if end == 0 {
				end = now.UnixMilli() // ongoing
			}
			if e.Start-pad < seg.End && end+pad > seg.Start {
				return true
			}
		}
		return false
	}
	for _, stream := range []string{"main", "sub"} {
		segs, err := r.Store.Segments(camID, stream, from, to)
		if err != nil {
			continue
		}
		var drop []store.Segment
		for _, s := range segs {
			if s.End <= to && cam.ModeAt(time.UnixMilli(s.Start)) == "motion" && !keep(s) {
				drop = append(drop, s)
			}
		}
		if len(drop) > 0 {
			slog.Debug("motion-only: removing footage without motion", "camera", camID, "stream", stream, "segments", len(drop))
			r.delete(drop)
		}
	}
}

// purgeThumbs removes thumbnail day folders (named YYYY-MM-DD) older than before.
func (r *Retention) purgeThumbs(before time.Time) {
	if r.ThumbDir == "" {
		return
	}
	days, err := os.ReadDir(r.ThumbDir)
	if err != nil {
		return
	}
	for _, d := range days {
		t, err := time.ParseInLocation("2006-01-02", d.Name(), time.Local)
		if err == nil && d.IsDir() && t.Before(before) {
			os.RemoveAll(filepath.Join(r.ThumbDir, d.Name()))
		}
	}
}

func (r *Retention) delete(segs []store.Segment) {
	for _, s := range segs {
		p := filepath.Join(r.RecRoot, s.Path)
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			slog.Error("delete segment", "path", p, "err", err)
			continue
		}
		r.Store.DeleteSegment(s.ID)
		// Remove empty day/month/year folders.
		dir := filepath.Dir(p)
		for i := 0; i < 3; i++ {
			if os.Remove(dir) != nil {
				break
			}
			dir = filepath.Dir(dir)
		}
	}
}
