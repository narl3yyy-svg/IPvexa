package camera

import (
	"bufio"
	"context"
	"errors"
	"io"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"ipvexa/internal/ai"
	"ipvexa/internal/motion"
)

// How often the detector looks at a camera's picture: often while motion waits to
// be confirmed, less once it is, and now and then when nothing moves (to learn
// which objects are standing still, such as parked cars).
const (
	detectPending   = 400 * time.Millisecond
	detectConfirmed = 2 * time.Second
	detectIdle      = 30 * time.Second
	aiFPS           = 3 // pictures per second handed to the detector at most

	// An object seen in the same place for this long is standing still: it doesn't
	// count, even if something else (a tree's shadow) moves over it.
	stillAfter = 20 * time.Second
	forgetSeen = 10 * time.Minute
	maxSeen    = 64
)

// WantedObjects returns the object groups a camera's motion is limited to, or nil
// when any motion counts.
func WantedObjects(setting string) map[ai.Group]bool {
	switch setting {
	case "people":
		return map[ai.Group]bool{ai.People: true}
	case "vehicles":
		return map[ai.Group]bool{ai.Vehicles: true}
	case "people_vehicles":
		return map[ai.Group]bool{ai.People: true, ai.Vehicles: true}
	}
	return nil
}

// ValidMotionObjects lists the accepted values of store.Camera.MotionObjects.
var ValidMotionObjects = []string{"", "people", "vehicles", "people_vehicles"}

// objectGate uses the object detector to tell what is moving during a motion event.
// With wanted groups set, the event only counts once one of them moves; otherwise
// the objects are just noted with the event. A nil gate does nothing.
type objectGate struct {
	eng  *ai.Engine
	want map[ai.Group]bool
	now  func() int64 // unix ms (tests replace it)

	mu       sync.Mutex
	frame    ai.Frame
	frameAt  int64
	moves    []move
	seen     []sighting
	active   bool // a motion event is waiting or open
	matched  bool // a wanted object moved during it
	labels   map[string]bool
	ranAt    int64
	ranFrame int64
}

type move struct {
	at    int64
	cells motion.Cells
}

type sighting struct {
	group       ai.Group
	box         ai.Box
	first, last int64
}

func newObjectGate(eng *ai.Engine, setting string) *objectGate {
	if !eng.Available() {
		return nil
	}
	return &objectGate{eng: eng, want: WantedObjects(setting), now: func() int64 { return time.Now().UnixMilli() }}
}

// filtering reports whether motion events wait for a wanted object.
func (g *objectGate) filtering() bool { return g != nil && g.want != nil }

func (g *objectGate) setFrame(f ai.Frame) {
	if g == nil {
		return
	}
	g.mu.Lock()
	g.frame, g.frameAt = f, g.now()
	g.mu.Unlock()
}

// addMotion records the moving cells of an analysed frame.
func (g *objectGate) addMotion(at int64, cells motion.Cells) {
	if g == nil {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	drop := 0
	for drop < len(g.moves) && at-g.moves[drop].at > 3000 {
		drop++
	}
	g.moves = g.moves[drop:]
	if cells.Count() > 0 {
		g.moves = append(g.moves, move{at, cells})
	}
}

// begin starts a motion event.
func (g *objectGate) begin() {
	if g == nil {
		return
	}
	g.mu.Lock()
	g.active, g.matched, g.labels = true, false, map[string]bool{}
	g.ranAt = 0 // look right away
	g.mu.Unlock()
}

// end finishes the event and returns what moved in it (see objectsString).
func (g *objectGate) end() string {
	if g == nil {
		return ""
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	s := objectsString(g.labels)
	g.active, g.matched, g.labels = false, false, nil
	return s
}

func (g *objectGate) isMatched() bool {
	if g == nil {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.matched
}

// objects returns what has moved so far in the current event, e.g. "car,person".
func (g *objectGate) objects() string {
	if g == nil {
		return ""
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return objectsString(g.labels)
}

func objectsString(labels map[string]bool) string {
	var l []string
	for k := range labels {
		l = append(l, k)
	}
	slices.Sort(l)
	return strings.Join(l, ",")
}

// run looks at the camera's latest picture whenever it's time, until ctx ends.
func (g *objectGate) run(ctx context.Context) {
	if g == nil {
		return
	}
	t := time.NewTicker(100 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		g.mu.Lock()
		now := g.now()
		every := detectIdle
		if g.active && !g.matched {
			every = detectPending
		} else if g.active {
			every = detectConfirmed
		}
		due := g.frameAt != 0 && g.frameAt != g.ranFrame && now-g.ranAt >= every.Milliseconds()
		f, at := g.frame, g.frameAt
		g.mu.Unlock()
		if !due {
			continue
		}
		objs, err := g.eng.Detect(f)
		g.mu.Lock()
		g.ranAt, g.ranFrame = g.now(), at
		if err == nil {
			g.evaluate(objs, at)
		}
		g.mu.Unlock()
	}
}

// evaluate takes the objects found in a picture taken at time at (unix ms). An
// object counts when it overlaps the area that moved around that time and it isn't
// one that has been standing in the same place. Call with g.mu held.
func (g *objectGate) evaluate(objs []ai.Object, at int64) {
	var moving motion.Cells
	for _, m := range g.moves {
		if m.at >= at-1500 && m.at <= at+700 {
			moving = moving.Or(m.cells)
		}
	}
	for _, o := range objs {
		grp := o.Group()
		if grp == "" {
			continue
		}
		still := g.sight(grp, o.Box, at)
		if !g.active || still || !overlaps(o.Box, moving) {
			continue
		}
		g.labels[o.Label] = true
		if g.want == nil || g.want[grp] {
			g.matched = true
		}
	}
}

// sight remembers an object and reports whether it has been standing in that
// place for a while. Call with g.mu held.
func (g *objectGate) sight(grp ai.Group, b ai.Box, at int64) bool {
	keep := g.seen[:0]
	for _, s := range g.seen {
		if at-s.last < forgetSeen.Milliseconds() {
			keep = append(keep, s)
		}
	}
	g.seen = keep
	for i := range g.seen {
		s := &g.seen[i]
		if s.group == grp && s.box.IoU(b) >= 0.6 {
			s.last = at
			return at-s.first >= stillAfter.Milliseconds()
		}
	}
	if len(g.seen) >= maxSeen {
		g.seen = g.seen[1:]
	}
	g.seen = append(g.seen, sighting{group: grp, box: b, first: at, last: at})
	return false
}

// overlaps reports whether a box covers any of the cells.
func overlaps(b ai.Box, cells motion.Cells) bool {
	if cells.Count() == 0 {
		return false
	}
	c0 := int(b.X * motion.Cols)
	c1 := int((b.X + b.W) * motion.Cols)
	r0 := int(b.Y * motion.Rows)
	r1 := int((b.Y + b.H) * motion.Rows)
	for r := max(r0, 0); r <= min(r1, motion.Rows-1); r++ {
		for c := max(c0, 0); c <= min(c1, motion.Cols-1); c++ {
			if cells.Has(r*motion.Cols + c) {
				return true
			}
		}
	}
	return false
}

// readPAM reads one picture in PAM format (ffmpeg's "pam" output, RGB).
func readPAM(r *bufio.Reader) (ai.Frame, error) {
	var f ai.Frame
	magic, err := r.ReadString('\n')
	if err != nil {
		return f, err
	}
	if strings.TrimSpace(magic) != "P7" {
		return f, errors.New("not a PAM picture")
	}
	depth := 0
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return f, err
		}
		line = strings.TrimSpace(line)
		if line == "ENDHDR" {
			break
		}
		k, v, _ := strings.Cut(line, " ")
		n, _ := strconv.Atoi(strings.TrimSpace(v))
		switch k {
		case "WIDTH":
			f.W = n
		case "HEIGHT":
			f.H = n
		case "DEPTH":
			depth = n
		}
	}
	if f.W <= 0 || f.H <= 0 || f.W > 4096 || f.H > 4096 || depth != 3 {
		return f, errors.New("unexpected PAM picture")
	}
	f.RGB = make([]byte, f.W*f.H*3)
	_, err = io.ReadFull(r, f.RGB)
	return f, err
}
