package camera

import (
	"bufio"
	"strings"
	"testing"

	"ipvexa/internal/ai"
	"ipvexa/internal/motion"
)

// cellsIn returns the motion cells covering a box.
func cellsIn(b ai.Box) motion.Cells {
	var c motion.Cells
	for r := int(b.Y * motion.Rows); r <= min(int((b.Y+b.H)*motion.Rows), motion.Rows-1); r++ {
		for col := int(b.X * motion.Cols); col <= min(int((b.X+b.W)*motion.Cols), motion.Cols-1); col++ {
			c.Set(r*motion.Cols + col)
		}
	}
	return c
}

func testGate(want string) *objectGate {
	return &objectGate{want: WantedObjects(want), now: func() int64 { return 0 }}
}

func TestGateWantsMovingPerson(t *testing.T) {
	g := testGate("people")
	parked := ai.Object{Label: "car", Score: 0.9, Box: ai.Box{X: 0.6, Y: 0.6, W: 0.2, H: 0.2}}
	// The parked car is seen before anything moves, and again later: it stands still.
	g.evaluate([]ai.Object{parked}, 1000)
	g.evaluate([]ai.Object{parked}, 31000)

	g.begin()
	// Branches move over the parked car: no event.
	g.addMotion(40000, cellsIn(parked.Box))
	g.evaluate([]ai.Object{parked}, 40000)
	if g.isMatched() {
		t.Fatal("parked car under moving branches confirmed the event")
	}
	// A car drives through: seen, but people were asked for.
	moving := ai.Object{Label: "car", Score: 0.9, Box: ai.Box{X: 0.1, Y: 0.5, W: 0.2, H: 0.2}}
	g.addMotion(41000, cellsIn(moving.Box))
	g.evaluate([]ai.Object{parked, moving}, 41000)
	if g.isMatched() {
		t.Fatal("a car confirmed a people-only event")
	}
	// A standing person far from the motion doesn't count either.
	far := ai.Object{Label: "person", Score: 0.8, Box: ai.Box{X: 0.0, Y: 0.0, W: 0.05, H: 0.1}}
	g.evaluate([]ai.Object{far}, 41200)
	if g.isMatched() {
		t.Fatal("a person away from the motion confirmed the event")
	}
	// A person walks through.
	walker := ai.Object{Label: "person", Score: 0.8, Box: ai.Box{X: 0.4, Y: 0.3, W: 0.05, H: 0.2}}
	g.addMotion(42000, cellsIn(walker.Box))
	g.evaluate([]ai.Object{walker}, 42000)
	if !g.isMatched() {
		t.Fatal("a walking person didn't confirm the event")
	}
	if got := g.end(); got != "car,person" {
		t.Errorf("objects %q", got)
	}
}

func TestGateAnyMotionNotesObjects(t *testing.T) {
	g := testGate("")
	if g.filtering() {
		t.Fatal("any motion shouldn't wait for objects")
	}
	g.begin()
	dog := ai.Object{Label: "dog", Score: 0.7, Box: ai.Box{X: 0.5, Y: 0.5, W: 0.1, H: 0.1}}
	g.addMotion(1000, cellsIn(dog.Box))
	g.evaluate([]ai.Object{dog}, 1100)
	if got := g.end(); got != "dog" {
		t.Errorf("objects %q", got)
	}
	// Nil gates (no detector) are safe to use.
	var none *objectGate
	none.begin()
	none.addMotion(0, motion.Cells{})
	if none.filtering() || none.isMatched() || none.end() != "" {
		t.Error("nil gate")
	}
}

func TestGateVehicles(t *testing.T) {
	g := testGate("people_vehicles")
	g.begin()
	truck := ai.Object{Label: "truck", Score: 0.7, Box: ai.Box{X: 0.2, Y: 0.4, W: 0.4, H: 0.3}}
	g.addMotion(5000, cellsIn(truck.Box))
	g.evaluate([]ai.Object{truck}, 5200)
	if !g.isMatched() {
		t.Fatal("a moving truck didn't confirm a people-and-vehicles event")
	}
}

func TestReadPAM(t *testing.T) {
	pic := "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 3\nMAXVAL 255\nTUPLTYPE RGB\nENDHDR\n" + "abcdef" +
		"P7\nWIDTH 1\nHEIGHT 1\nDEPTH 3\nMAXVAL 255\nTUPLTYPE RGB\nENDHDR\n" + "xyz"
	r := bufio.NewReader(strings.NewReader(pic))
	f, err := readPAM(r)
	if err != nil || f.W != 2 || f.H != 1 || string(f.RGB) != "abcdef" {
		t.Fatalf("first: %+v %v", f, err)
	}
	f, err = readPAM(r)
	if err != nil || string(f.RGB) != "xyz" {
		t.Fatalf("second: %+v %v", f, err)
	}
	if _, err := readPAM(r); err == nil {
		t.Fatal("expected end of stream")
	}
}
