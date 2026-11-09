// Package motion finds movement in a stream of small greyscale frames.
//
// Frames are W×H bytes (one byte per pixel). The picture is divided into a
// Cols×Rows grid; a cell "moves" when enough of its pixels changed since the last
// frame. Cells can be masked out (trees, roads, timestamps). Results are reported
// per frame as a Cells bitmask so events can be searched by area later.
//
// Two filters keep swaying trees, flags, water and rain from counting as motion:
//   - Cells that move most of the time are learned as "busy" and ignored until they
//     calm down (a tree in the wind is busy for minutes; a person passes in seconds).
//   - An event only starts when the moving area travels across the picture or grows
//     (something walking or driving through); a branch waving in place does neither.
package motion

import (
	"encoding/hex"
	"math"
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
	// KeepBusy turns off the busy-cell filter (every moving cell counts).
	KeepBusy bool

	prev    []byte
	busy    [N]float32 // per cell: how much of the time it has been moving lately, 0…1
	flagged [N]bool    // per cell: currently treated as busy
}

// Busy-cell filter. A cell's activity rises quickly (about 15 s at 5 frames/s) and
// falls slowly (about 2 minutes), so a tree that sways on and off stays ignored.
const (
	busyRise  = 1.0 / 75
	busyFall  = 1.0 / 600
	busyLimit = 0.4  // ignore a cell moving in more than ~40% of recent frames
	busyCalm  = 0.25 // and count it again once it has calmed down below this
)

// Result of one frame.
type Result struct {
	Cells Cells   // moving cells (mask and busy cells removed)
	Busy  Cells   // cells currently ignored because they move nearly all the time
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
	var raw Cells
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
				raw.Set(i)
			}
		}
	}
	copy(d.prev, frame)
	if unmasked == 0 {
		return Result{}
	}
	if float64(raw.Count())/float64(unmasked) > 0.65 {
		return Result{Lighting: true} // not learned as busy either
	}
	for i := 0; i < N; i++ {
		if d.Mask.Has(i) {
			continue
		}
		moving := raw.Has(i)
		if moving {
			d.busy[i] += (1 - d.busy[i]) * busyRise
		} else {
			d.busy[i] -= d.busy[i] * busyFall
		}
		// Hysteresis: once busy, a cell stays ignored until it is well below the limit.
		d.flagged[i] = d.busy[i] >= busyLimit || (d.flagged[i] && d.busy[i] >= busyCalm)
		isBusy := d.flagged[i] && !d.KeepBusy
		if isBusy {
			r.Busy.Set(i)
		}
		if moving && !isBusy {
			r.Cells.Set(i)
		}
	}
	r.Level = float64(r.Cells.Count()) / float64(unmasked)
	return r
}

// centroid of a set of cells, in cell units.
func (c Cells) centroid() (x, y float64, n int) {
	for i := 0; i < N; i++ {
		if c.Has(i) {
			x += float64(i%Cols) + 0.5
			y += float64(i/Cols) + 0.5
			n++
		}
	}
	if n > 0 {
		x /= float64(n)
		y /= float64(n)
	}
	return
}

// Event is one stretch of motion.
type Event struct {
	Start, End int64 // unix ms; End is 0 while ongoing
	Cells      Cells // every cell that moved during the event
	Peak       float64
}

// Tracker turns per-frame results into events: an event starts once MinFrames
// frames with motion are seen within Window ms (so single-frame noise is ignored)
// and the moving area has travelled or grown (so things moving in place, like
// branches, are ignored). It ends after Quiet ms without motion.
type Tracker struct {
	MinFrames int     // default 2
	Window    int64   // default 2500 ms
	Quiet     int64   // default 4000 ms
	Travel    float64 // cells the moving area must travel; default 1.5, negative = don't check

	recent  []int64 // times of recent moving frames (before an event starts)
	spots   []spot  // the moving area in those frames
	pending Cells   // cells seen in those frames
	peak    float64
	last    int64
	current *Event
}

type spot struct {
	x, y float64
	n    int
}

// Big moving areas (a car close to the camera) start an event without travelling.
const bigLevel = 0.2

// travelled reports whether the moving area went somewhere: from the first frame
// to the latest, its centre moved at least dist cells, or it grew by 3 cells or
// more (something coming closer). Comparing only the ends ignores back-and-forth.
func travelled(spots []spot, dist float64) bool {
	if len(spots) < 2 {
		return false
	}
	a, b := spots[0], spots[len(spots)-1]
	return math.Hypot(b.x-a.x, b.y-a.y) >= dist || b.n-a.n >= 3
}

// Update feeds one frame result at time t (unix ms). It returns a started event
// (once, when motion begins) and a finished event (once, when it ends).
func (tr *Tracker) Update(t int64, r Result) (started, ended *Event) {
	minFrames, window, quiet := tr.MinFrames, tr.Window, tr.Quiet
	if minFrames <= 0 {
		minFrames = 2
	}
	if window <= 0 {
		window = 2500
	}
	travel := tr.Travel
	if travel == 0 {
		travel = 1.5
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
	drop := 0
	for drop < len(tr.recent) && t-tr.recent[drop] >= window {
		drop++
	}
	tr.recent, tr.spots = tr.recent[drop:], tr.spots[drop:]
	if len(tr.recent) == 0 {
		tr.recent, tr.spots = tr.recent[:0], tr.spots[:0]
		tr.pending, tr.peak = Cells{}, 0
	}
	if !moving {
		return nil, nil
	}
	x, y, n := r.Cells.centroid()
	tr.recent = append(tr.recent, t)
	tr.spots = append(tr.spots, spot{x, y, n})
	tr.pending = tr.pending.Or(r.Cells)
	tr.peak = max(tr.peak, r.Level)
	if len(tr.recent) < minFrames {
		return nil, nil
	}
	if travel > 0 && tr.peak < bigLevel && !travelled(tr.spots, travel) {
		return nil, nil
	}
	tr.current = &Event{Start: tr.recent[0], Cells: tr.pending, Peak: tr.peak}
	tr.recent, tr.spots, tr.pending, tr.peak = tr.recent[:0], tr.spots[:0], Cells{}, 0
	e := *tr.current
	return &e, nil
}

// Flush ends an ongoing event (e.g. when the stream stops).
func (tr *Tracker) Flush() *Event {
	tr.recent, tr.spots, tr.pending, tr.peak = tr.recent[:0], tr.spots[:0], Cells{}, 0
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
