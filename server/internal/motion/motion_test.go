package motion

import "testing"

func frame(fill byte) []byte {
	f := make([]byte, W*H)
	for i := range f {
		f[i] = fill
	}
	return f
}

// paint fills one grid cell with a brightness.
func paint(f []byte, cx, cy int, v byte) {
	for y := cy * cellH; y < (cy+1)*cellH; y++ {
		for x := cx * cellW; x < (cx+1)*cellW; x++ {
			f[y*W+x] = v
		}
	}
}

func TestCellsRoundTrip(t *testing.T) {
	var c Cells
	for _, i := range []int{0, 5, 63, 64, 100, N - 1} {
		c.Set(i)
	}
	s := c.String()
	if len(s) != N/4 {
		t.Fatalf("encoded length %d, want %d", len(s), N/4)
	}
	if ParseCells(s) != c {
		t.Errorf("round trip failed: %s", s)
	}
	if ParseCells("zz") != (Cells{}) {
		t.Error("invalid input should give an empty set")
	}
	var o Cells
	o.Set(100)
	if !c.Overlaps(o) || c.Count() != 6 {
		t.Error("overlap/count")
	}
}

func TestDetector(t *testing.T) {
	d := &Detector{}
	bg := frame(80)
	if r := d.Feed(bg); r.Cells.Count() != 0 {
		t.Fatal("first frame must not report motion")
	}
	if r := d.Feed(frame(80)); r.Cells.Count() != 0 {
		t.Fatal("static scene reported motion")
	}
	// Small noise is ignored.
	noisy := frame(84)
	if r := d.Feed(noisy); r.Cells.Count() != 0 {
		t.Fatal("sensor noise reported as motion")
	}
	// Something bright moves into cell (3,2).
	f := frame(84)
	paint(f, 3, 2, 220)
	r := d.Feed(f)
	if !r.Cells.Has(2*Cols+3) || r.Cells.Count() != 1 {
		t.Fatalf("expected only cell (3,2), got %d cells", r.Cells.Count())
	}
	// The same change in a masked cell is ignored.
	d2 := &Detector{}
	d2.Mask.Set(2*Cols + 3)
	d2.Feed(frame(84))
	if r := d2.Feed(f); r.Cells.Count() != 0 {
		t.Fatal("masked cell reported motion")
	}
	// A whole-picture change is lighting, not motion.
	if r := d.Feed(frame(200)); !r.Lighting || r.Cells.Count() != 0 {
		t.Fatal("lighting change not recognised")
	}
}

func TestTracker(t *testing.T) {
	var moving, still Result
	moving.Cells.Set(10)
	moving.Level = 0.1
	tr := &Tracker{Travel: -1}
	if s, _ := tr.Update(0, moving); s != nil {
		t.Fatal("one frame must not start an event")
	}
	s, _ := tr.Update(250, moving)
	if s == nil || s.Start != 0 {
		t.Fatal("event should start (at the first moving frame) on the second one")
	}
	var other Result
	other.Cells.Set(20)
	tr.Update(500, other)
	tr.Update(2000, still)
	if _, e := tr.Update(4000, still); e != nil {
		t.Fatal("ended too early")
	}
	_, e := tr.Update(4600, still)
	if e == nil || e.End != 500 || !e.Cells.Has(10) || !e.Cells.Has(20) {
		t.Fatalf("bad end event %+v", e)
	}
	if tr.Active() || tr.Flush() != nil {
		t.Fatal("tracker should be idle")
	}
}

func TestTrackerWindow(t *testing.T) {
	var moving, still Result
	moving.Cells.Set(3)
	tr := &Tracker{Window: 1000, Travel: -1}
	tr.Update(0, moving)
	tr.Update(200, still)
	if s, _ := tr.Update(800, moving); s == nil || s.Start != 0 {
		t.Fatal("two moving frames within a second, with a still frame between, should start an event")
	}
	tr2 := &Tracker{Window: 1000, Travel: -1}
	tr2.Update(0, moving)
	if s, _ := tr2.Update(1500, moving); s != nil {
		t.Fatal("moving frames 1.5 s apart are noise, not an event")
	}
}

// A branch waving in the same two cells never starts an event; something walking
// across the picture does.
func TestTrackerIgnoresMotionInPlace(t *testing.T) {
	var a, b Result
	a.Cells.Set(2*Cols + 5)
	b.Cells.Set(2*Cols + 6)
	a.Level, b.Level = 0.01, 0.01
	tr := &Tracker{}
	for i := int64(0); i < 40; i++ {
		r := a
		if i%2 == 1 {
			r = b
		}
		if s, _ := tr.Update(i*200, r); s != nil {
			t.Fatalf("motion in place started an event at frame %d", i)
		}
	}
	tr2 := &Tracker{}
	var started *Event
	for x := 0; x < 6 && started == nil; x++ {
		var r Result
		r.Cells.Set(4*Cols + x)
		r.Level = 0.01
		started, _ = tr2.Update(int64(x)*200, r)
	}
	if started == nil || started.Start != 0 {
		t.Fatalf("walking across the picture should start an event at its first frame, got %+v", started)
	}
	// A big moving area (close to the camera) starts at once.
	tr3 := &Tracker{}
	var big Result
	for i := 0; i < 40; i++ {
		big.Cells.Set(i)
	}
	big.Level = 0.3
	tr3.Update(0, big)
	if s, _ := tr3.Update(200, big); s == nil {
		t.Fatal("a big moving area should start an event")
	}
}

// A cell that keeps moving (a tree in the wind) becomes busy and is ignored; once
// it has been still for a while it counts again.
func TestDetectorLearnsBusyCells(t *testing.T) {
	d := &Detector{}
	tree := 3*Cols + 2
	f0, f1 := frame(80), frame(80)
	paint(f1, 2, 3, 200)
	d.Feed(f0)
	first := d.Feed(f1)
	if !first.Cells.Has(tree) {
		t.Fatal("a new movement should count at first")
	}
	// Sway for a minute at 5 frames/s.
	var r Result
	for i := 0; i < 300; i++ {
		if i%2 == 0 {
			r = d.Feed(f0)
		} else {
			r = d.Feed(f1)
		}
	}
	if r.Cells.Has(tree) || !r.Busy.Has(tree) {
		t.Fatal("a cell moving all the time should be ignored as busy")
	}
	// Something moving elsewhere still counts.
	f2 := frame(80)
	paint(f2, 10, 5, 200)
	if r := d.Feed(f2); !r.Cells.Has(5*Cols + 10) {
		t.Fatal("other cells must still detect motion")
	}
	// Calm for five minutes: the cell counts again.
	for i := 0; i < 1500; i++ {
		d.Feed(f0)
	}
	if r := d.Feed(f1); !r.Cells.Has(tree) {
		t.Fatal("a calm cell should detect motion again")
	}
	// With KeepBusy every moving cell counts.
	k := &Detector{KeepBusy: true}
	k.Feed(f0)
	for i := 0; i < 300; i++ {
		if i%2 == 0 {
			r = k.Feed(f1)
		} else {
			r = k.Feed(f0)
		}
	}
	if !r.Cells.Has(tree) {
		t.Fatal("KeepBusy should report busy cells")
	}
}
