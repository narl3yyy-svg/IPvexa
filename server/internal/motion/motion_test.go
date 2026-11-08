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
	tr := &Tracker{}
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
	tr := &Tracker{}
	tr.Update(0, moving)
	tr.Update(200, still)
	if s, _ := tr.Update(800, moving); s == nil || s.Start != 0 {
		t.Fatal("two moving frames within a second, with a still frame between, should start an event")
	}
	tr2 := &Tracker{}
	tr2.Update(0, moving)
	if s, _ := tr2.Update(1500, moving); s != nil {
		t.Fatal("moving frames 1.5 s apart are noise, not an event")
	}
}
