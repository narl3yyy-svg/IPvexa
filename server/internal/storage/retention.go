// Package storage enforces retention: per-camera age limits and a global
// minimum of free disk space, always deleting the oldest footage first.
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
	MinFreePct float64 // keep at least this much of the disk free
	Interval   time.Duration
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

	// Disk-space guard: delete oldest footage across all cameras until enough is free.
	for i := 0; i < 1000; i++ {
		free, err := FreePct(r.RecRoot)
		if err != nil || free >= r.MinFreePct {
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
