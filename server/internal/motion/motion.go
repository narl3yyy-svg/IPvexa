// Package motion finds movement in a stream of small greyscale frames.
//
// Frames are W×H bytes (one byte per pixel). The picture is divided into a
// Cols×Rows grid; a cell "moves" when enough of its pixels changed since the last
// frame. Cells can be masked out (trees, roads, timestamps). Results are reported
// per frame as a Cells bitmask so events can be searched by area later.
package motion

import (
	"encoding/hex"
	"strings"
)

const (
	W    = 64 // analysis frame size
	H    = 36
	Cols = 16 // motion grid
	Rows = 9
	N    = Cols * Rows

	cellW = W / Cols
	cellH = H / Rows
)

// Cells is a set of grid cells, bit i = cell (i%Cols, i/Cols).
type Cells [(N + 63) / 64]uint64

func (c *Cells) Set(i int)       { c[i/64] |= 1 << (i % 64) }
func (c Cells) Has(i int) bool   { return c[i/64]&(1<<(i%64)) != 0 }
func (c Cells) Or(o Cells) Cells { return Cells{c[0] | o[0], c[1] | o[1], c[2] | o[2]} }
func (c Cells) Overlaps(o Cells) bool {
	return c[0]&o[0] != 0 || c[1]&o[1] != 0 || c[2]&o[2] != 0
}
func (c Cells) Count() int {
	n := 0
	for i := 0; i < N; i++ {
		if c.Has(i) {
			n++
		}
	}
	return n
}

// String encodes the cells as a hex string of N/4 digits (4 cells per digit, in order).
func (c Cells) String() string {
	b := make([]byte, (N+7)/8)
	for i := 0; i < N; i++ {
		if c.Has(i) {
			b[i/8] |= 1 << (7 - i%8)
		}
	}
	return hex.EncodeToString(b)
}

// ParseCells reverses String. Invalid input gives an empty set.
func ParseCells(s string) Cells {
	var c Cells
	b, err := hex.DecodeString(strings.TrimSpace(s))
	if err != nil {
		return c
	}
	for i := 0; i < N && i/8 < len(b); i++ {
		if b[i/8]&(1<<(7-i%8)) != 0 {
			c.Set(i)
		}
	}
	return c
}

// Detector compares consecutive frames. Not safe for concurrent use.
type Detector struct {
	Sensitivity int   // 1 (only big changes) … 100 (very sensitive); 0 means 50
	Mask        Cells // cells to ignore

	prev []byte
}

// Result of one frame.
type Result struct {
	Cells Cells   // moving cells (mask applied)
	Level float64 // fraction of unmasked cells moving, 0…1
	// Lighting is true when most of the picture changed at once (day/night switch,
	// auto-exposure, a light turned on). Such frames are not reported as motion.
	Lighting bool
}

func (d *Detector) thresholds() (pixel int, perCell int) {
	s := d.Sensitivity
	if s <= 0 {
		s = 50
	}
	if s > 100 {
		s = 100
	}
	// Pixel brightness change needed (out of 255) and changed pixels needed per cell.
	// Calibrated on real cameras: compression and sensor noise rarely change more
	// than 3 pixels of a cell by 26+ levels between frames.
	pixel = 14 + (100-s)*24/100 // 14 … 38 (50 → 26)
	perCell = 2 + (100-s)*6/100 // 2 … 8 of 16 (50 → 5)
	return
}

// Feed analyses the next frame (len W*H). The first frame only primes the detector.
func (d *Detector) Feed(frame []byte) Result {
	var r Result
	if len(frame) != W*H {
		return r
	}
	if d.prev == nil {
		d.prev = append([]byte(nil), frame...)
		return r
	}
	pixTh, cellTh := d.thresholds()
	unmasked := 0
	for cy := 0; cy < Rows; cy++ {
		for cx := 0; cx < Cols; cx++ {
			i := cy*Cols + cx
			if d.Mask.Has(i) {
				continue
			}
			unmasked++
			changed := 0
			for y := cy * cellH; y < (cy+1)*cellH; y++ {
				row := y * W
				for x := cx * cellW; x < (cx+1)*cellW; x++ {
					diff := int(frame[row+x]) - int(d.prev[row+x])
					if diff < 0 {
						diff = -diff
					}
					if diff >= pixTh {
						changed++
					}
				}
			}
			if changed >= cellTh {
				r.Cells.Set(i)
			}
		}
	}
	copy(d.prev, frame)
	if unmasked == 0 {
		return Result{}
	}
	r.Level = float64(r.Cells.Count()) / float64(unmasked)
	if r.Level > 0.65 {
		return Result{Lighting: true}
	}
	return r
}

// Event is one stretch of motion.
type Event struct {
	Start, End int64 // unix ms; End is 0 while ongoing
	Cells      Cells // every cell that moved during the event
	Peak       float64
}

// Tracker turns per-frame results into events: an event starts once MinFrames
// frames with motion are seen within Window ms (so single-frame noise is ignored),
// and ends after Quiet ms without motion.
type Tracker struct {
	MinFrames int   // default 2
	Window    int64 // default 1000 ms
	Quiet     int64 // default 4000 ms

	recent  []int64 // times of recent moving frames (before an event starts)
	pending Cells   // cells seen in those frames
	peak    float64
	last    int64
	current *Event
}

// Update feeds one frame result at time t (unix ms). It returns a started event
// (once, when motion begins) and a finished event (once, when it ends).
func (tr *Tracker) Update(t int64, r Result) (started, ended *Event) {
	minFrames, window, quiet := tr.MinFrames, tr.Window, tr.Quiet
	if minFrames <= 0 {
		minFrames = 2
	}
	if window <= 0 {
		window = 1000
	}
	if quiet <= 0 {
		quiet = 4000
	}
	moving := r.Cells.Count() > 0
	if moving {
		tr.last = t
	}
	if tr.current != nil {
		if moving {
			tr.current.Cells = tr.current.Cells.Or(r.Cells)
			tr.current.Peak = max(tr.current.Peak, r.Level)
		} else if t-tr.last >= quiet {
			e := *tr.current
			e.End = tr.last
			tr.current = nil
			return nil, &e
		}
		return nil, nil
	}
	// Not in an event: keep the moving frames of the last window.
	keep := tr.recent[:0]
	for _, ts := range tr.recent {
		if t-ts < window {
			keep = append(keep, ts)
		}
	}
	tr.recent = keep
	if len(tr.recent) == 0 {
		tr.pending, tr.peak = Cells{}, 0
	}
	if !moving {
		return nil, nil
	}
	tr.recent = append(tr.recent, t)
	tr.pending = tr.pending.Or(r.Cells)
	tr.peak = max(tr.peak, r.Level)
	if len(tr.recent) < minFrames {
		return nil, nil
	}
	tr.current = &Event{Start: tr.recent[0], Cells: tr.pending, Peak: tr.peak}
	tr.recent, tr.pending, tr.peak = tr.recent[:0], Cells{}, 0
	e := *tr.current
	return &e, nil
}

// Flush ends an ongoing event (e.g. when the stream stops).
func (tr *Tracker) Flush() *Event {
	tr.recent, tr.pending, tr.peak = tr.recent[:0], Cells{}, 0
	if tr.current == nil {
		return nil
	}
	e := *tr.current
	e.End = tr.last
	tr.current = nil
	return &e
}

// Active reports whether an event is in progress.
func (tr *Tracker) Active() bool { return tr.current != nil }
