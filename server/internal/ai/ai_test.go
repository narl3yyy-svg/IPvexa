package ai

import (
	"image"
	_ "image/jpeg"
	_ "image/png"
	"math"
	"os"
	"path/filepath"
	"testing"
)

// fakeOutput builds a YOLOX output with one confident object at grid cell (gx, gy)
// of stride st, with class c, centre offset 0.5 and size w×h pixels.
func fakeOutput(size, st, gx, gy, c int, w, h float64) []float32 {
	out := make([]float32, cells(size)*85)
	k := 0
	for _, s := range []int{8, 16, 32} {
		if s == st {
			k += gy*(size/s) + gx
			break
		}
		k += (size / s) * (size / s)
	}
	row := out[k*85 : (k+1)*85]
	row[0], row[1] = 0.5, 0.5
	row[2], row[3] = float32(math.Log(w/float64(st))), float32(math.Log(h/float64(st)))
	row[4] = 0.9
	row[5+c] = 0.9
	return out
}

func TestDecode(t *testing.T) {
	// A person centred at (100, 60) in a 640-wide input made from a 1280×720 frame
	// (scale 0.5), 40×80 pixels in the input.
	out := fakeOutput(640, 8, 12, 7, 0, 40, 80)
	objs := decode(out, 640, 0.5, 1280, 720, 0.5)
	if len(objs) != 1 || objs[0].Label != "person" || objs[0].Group() != People {
		t.Fatalf("got %+v", objs)
	}
	b := objs[0].Box
	// Centre (100, 60)/0.5 = (200, 120) in the frame; size 80×160.
	want := Box{X: 160.0 / 1280, Y: 40.0 / 720, W: 80.0 / 1280, H: 160.0 / 720}
	if math.Abs(b.X-want.X) > 1e-6 || math.Abs(b.Y-want.Y) > 1e-6 || math.Abs(b.W-want.W) > 1e-6 || math.Abs(b.H-want.H) > 1e-6 {
		t.Errorf("box %+v, want %+v", b, want)
	}
	// Objects IPvexa doesn't use (class 58, potted plant) are left out.
	if objs := decode(fakeOutput(640, 16, 3, 3, 58, 50, 50), 640, 1, 640, 640, 0.5); len(objs) != 0 {
		t.Errorf("potted plant reported: %+v", objs)
	}
	// Low scores are left out: 0.9*0.9 = 0.81 < 0.85.
	if objs := decode(out, 640, 0.5, 1280, 720, 0.85); len(objs) != 0 {
		t.Errorf("low score reported: %+v", objs)
	}
}

func TestNMS(t *testing.T) {
	objs := []Object{
		{Label: "car", Score: 0.6, Box: Box{0.1, 0.1, 0.3, 0.3}},
		{Label: "truck", Score: 0.9, Box: Box{0.11, 0.1, 0.3, 0.3}}, // same vehicle, better score
		{Label: "person", Score: 0.7, Box: Box{0.12, 0.1, 0.1, 0.3}},
		{Label: "car", Score: 0.8, Box: Box{0.6, 0.6, 0.2, 0.2}},
	}
	got := nms(objs, 0.45)
	if len(got) != 3 || got[0].Label != "truck" {
		t.Fatalf("got %+v", got)
	}
}

func TestPrepare(t *testing.T) {
	f := Frame{W: 4, H: 2, RGB: make([]byte, 4*2*3)}
	for i := 0; i < 8; i++ {
		f.RGB[i*3], f.RGB[i*3+1], f.RGB[i*3+2] = 10, 20, 30
	}
	dst := make([]float32, 3*8*8)
	r := prepare(f, 8, dst)
	if r != 2 {
		t.Fatalf("scale %v", r)
	}
	// Blue plane first; the picture fills the top 4 rows, the rest is grey.
	if dst[0] != 30 || dst[64] != 20 || dst[128] != 10 {
		t.Errorf("pixel 0 = %v %v %v", dst[0], dst[64], dst[128])
	}
	if dst[5*8] != padValue || dst[64+7*8+7] != padValue {
		t.Error("padding not grey")
	}
}

func TestGroupOf(t *testing.T) {
	for label, want := range map[string]Group{"person": People, "truck": Vehicles, "bicycle": Vehicles, "dog": Animals, "bird": Animals, "potted plant": "", "bench": ""} {
		if g := GroupOf(label); g != want {
			t.Errorf("%s: %q, want %q", label, g, want)
		}
	}
}

// TestRealModel runs the installed model on a picture, when both are given:
// IPVEXA_AI_DIR=/var/lib/ipvexa/ai IPVEXA_AI_IMAGE=street.jpg go test ./internal/ai -run RealModel -v
func TestRealModel(t *testing.T) {
	dir, img := os.Getenv("IPVEXA_AI_DIR"), os.Getenv("IPVEXA_AI_IMAGE")
	if dir == "" || img == "" {
		t.Skip("set IPVEXA_AI_DIR and IPVEXA_AI_IMAGE")
	}
	e := Open(dir)
	if !e.Available() {
		t.Fatal(e.Status().Error)
	}
	fh, err := os.Open(img)
	if err != nil {
		t.Fatal(err)
	}
	defer fh.Close()
	pic, _, err := image.Decode(fh)
	if err != nil {
		t.Fatal(err)
	}
	b := pic.Bounds()
	f := Frame{W: b.Dx(), H: b.Dy(), RGB: make([]byte, b.Dx()*b.Dy()*3)}
	for y := 0; y < f.H; y++ {
		for x := 0; x < f.W; x++ {
			r, g, bl, _ := pic.At(b.Min.X+x, b.Min.Y+y).RGBA()
			i := (y*f.W + x) * 3
			f.RGB[i], f.RGB[i+1], f.RGB[i+2] = byte(r>>8), byte(g>>8), byte(bl>>8)
		}
	}
	for i := 0; i < 3; i++ {
		objs, err := e.Detect(f)
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			for _, o := range objs {
				t.Logf("%-10s %.2f  x=%.2f y=%.2f w=%.2f h=%.2f", o.Label, o.Score, o.Box.X, o.Box.Y, o.Box.W, o.Box.H)
			}
		}
	}
	st := e.Status()
	t.Logf("model %s, %d runs, %.0f ms per picture (%s)", st.Model, st.Runs, st.AvgMs, filepath.Base(img))
}
