// Package ai finds people, vehicles and animals in camera pictures, on this machine
// (no internet or cloud service is used). It runs a YOLOX object detection model
// with ONNX Runtime, both of which the installer puts in the server's "ai" folder.
// Without them the server works as before and motion isn't filtered.
package ai

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

// Models, best first, with their input size.
var models = []struct {
	file string
	size int
}{
	{"yolox_s.onnx", 640},
	{"yolox_tiny.onnx", 416},
	{"yolox_nano.onnx", 416},
}

// slowModel is the time per picture above which a smaller model is used.
const slowModel = 150 * time.Millisecond

// Engine runs the detector. One picture is analysed at a time (each analysis
// already uses several CPU cores); cameras wait their turn.
type Engine struct {
	mu    sync.Mutex
	sess  *ortSession
	size  int
	model string
	err   string
	input []float32

	runs  int
	total time.Duration
}

// Status describes the engine for the app.
type Status struct {
	Available bool    `json:"available"`
	Error     string  `json:"error,omitempty"`
	Model     string  `json:"model,omitempty"`
	Runs      int     `json:"runs"`
	AvgMs     float64 `json:"avg_ms,omitempty"` // time per picture
}

func libNames() []string {
	if runtime.GOOS == "darwin" {
		return []string{"libonnxruntime*.dylib"}
	}
	return []string{"libonnxruntime.so.*", "libonnxruntime.so"}
}

func findLib(dir string) string {
	for _, pat := range libNames() {
		if m, _ := filepath.Glob(filepath.Join(dir, pat)); len(m) > 0 {
			return m[len(m)-1]
		}
	}
	// A system-wide ONNX Runtime (e.g. from the distribution's packages).
	if runtime.GOOS == "darwin" {
		return "libonnxruntime.dylib"
	}
	return "libonnxruntime.so.1"
}

// Open loads ONNX Runtime and the model from dir. It always returns an engine;
// Available reports whether it works (and Status why not).
func Open(dir string) *Engine {
	e := &Engine{}
	if err := e.open(dir); err != nil {
		e.err = err.Error()
		slog.Info("object detection not available; motion is not filtered by object", "dir", dir, "reason", e.err)
		return e
	}
	slog.Info("object detection ready", "model", e.model, "size", e.size)
	return e
}

func (e *Engine) open(dir string) error {
	var found []string
	for _, m := range models {
		if _, err := os.Stat(filepath.Join(dir, m.file)); err == nil {
			found = append(found, m.file)
		}
	}
	if len(found) == 0 {
		return fmt.Errorf("no model in %s (the installer downloads it)", dir)
	}
	lib := findLib(dir)
	o, err := loadORT(lib)
	if err != nil {
		return fmt.Errorf("could not load ONNX Runtime (%s): %w", lib, err)
	}
	threads := min(4, max(1, runtime.NumCPU()/2))
	for i, file := range found {
		took, err := e.load(o, filepath.Join(dir, file), threads)
		if err != nil {
			return err
		}
		// On a slow processor, use a smaller (faster, a little less accurate) model.
		if took > slowModel && i < len(found)-1 {
			slog.Info("object detection: the processor is slow for this model, trying a smaller one", "model", file, "ms", took.Milliseconds())
			e.sess.close()
			e.sess = nil
			continue
		}
		break
	}
	return nil
}

// load opens a model, checks it gives what decode expects and returns the time it
// takes per picture.
func (e *Engine) load(o *ortLib, model string, threads int) (time.Duration, error) {
	size := 640
	for _, m := range models {
		if m.file == filepath.Base(model) {
			size = m.size
		}
	}
	s, err := o.newSession(model, threads)
	if err != nil {
		return 0, fmt.Errorf("could not load the model: %w", err)
	}
	input := make([]float32, 3*size*size)
	shape := []int64{1, 3, int64(size), int64(size)}
	var took time.Duration
	for i := 0; i < 3; i++ { // the first run warms up
		t := time.Now()
		_, dims, err := s.run(input, shape)
		if err != nil {
			s.close()
			return 0, fmt.Errorf("the model doesn't run: %w", err)
		}
		if len(dims) != 3 || dims[1] != int64(cells(size)) || dims[2] != 85 {
			s.close()
			return 0, fmt.Errorf("unexpected model output %v", dims)
		}
		if i > 0 {
			took += time.Since(t) / 2
		}
	}
	e.sess, e.size, e.model, e.input = s, size, filepath.Base(model), input
	return took, nil
}

// Available reports whether objects can be detected.
func (e *Engine) Available() bool { return e != nil && e.sess != nil }

// Size is the picture size the model works on; frames should fit in Size×Size.
func (e *Engine) Size() int {
	if e == nil {
		return 0
	}
	return e.size
}

func (e *Engine) Status() Status {
	if e == nil {
		return Status{Error: "turned off"}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	st := Status{Available: e.sess != nil, Error: e.err, Model: e.model, Runs: e.runs}
	if e.runs > 0 {
		st.AvgMs = float64(e.total.Microseconds()) / 1000 / float64(e.runs)
	}
	return st
}

// MinScore is how sure the model must be to count an object.
const MinScore = 0.5

// Detect finds people, vehicles and animals in a frame.
func (e *Engine) Detect(f Frame) ([]Object, error) {
	if !e.Available() {
		return nil, errors.New("object detection is not available")
	}
	if f.W <= 0 || f.H <= 0 || len(f.RGB) < f.W*f.H*3 {
		return nil, errors.New("bad frame")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	t := time.Now()
	scale := prepare(f, e.size, e.input)
	out, _, err := e.sess.run(e.input, []int64{1, 3, int64(e.size), int64(e.size)})
	if err != nil {
		return nil, err
	}
	e.runs++
	e.total += time.Since(t)
	return decode(out, e.size, scale, f.W, f.H, MinScore), nil
}
