package camera

import (
	"context"
	"log/slog"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"ipvexa/internal/store"
)

// Manager owns the running streams for every enabled camera.
type Manager struct {
	Store   *store.Store
	RecRoot string
	FFmpeg  string
	FFprobe string
	// OnEvent is called when a motion event starts (started=true) and when it ends.
	OnEvent func(e store.Event, started bool)

	mu      sync.Mutex
	idxMu   sync.Mutex // serialises indexing so a segment is never filed twice
	running map[int64]*running
	ctx     context.Context
}

type running struct {
	cam    store.Camera
	main   *Stream
	sub    *Stream // nil when the camera has no substream
	cancel context.CancelFunc
	wg     sync.WaitGroup
	motion atomic.Bool // motion right now
	mode   string      // recording mode in effect (see store.Camera.ModeAt)
}

type CameraStatus struct {
	Main   *StreamStatus `json:"main,omitempty"`
	Sub    *StreamStatus `json:"sub,omitempty"`
	Motion bool          `json:"motion"`
}

func (m *Manager) Start(ctx context.Context) error {
	m.ctx = ctx
	m.running = map[int64]*running{}
	m.Store.CloseOpenEvents()
	cams, err := m.Store.Cameras()
	if err != nil {
		return err
	}
	for _, c := range cams {
		m.Apply(c)
	}
	go m.runIndexer(ctx)
	go m.runScheduler(ctx)
	return nil
}

// runScheduler restarts cameras whose recording schedule switches mode.
func (m *Manager) runScheduler(ctx context.Context) {
	t := time.NewTicker(20 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		now := time.Now()
		var due []store.Camera
		m.mu.Lock()
		for _, r := range m.running {
			if len(r.cam.RecordSchedule) > 0 && r.cam.ModeAt(now) != r.mode {
				due = append(due, r.cam)
			}
		}
		m.mu.Unlock()
		for _, c := range due {
			slog.Info("recording schedule: switching mode", "camera", c.ID, "mode", c.ModeAt(now))
			m.Apply(c)
		}
	}
}

// IncomingDir is where ffmpeg writes segments before the indexer files them away.
func (m *Manager) IncomingDir(camID int64, stream string) string {
	return filepath.Join(m.RecRoot, strconv.FormatInt(camID, 10), stream, "incoming")
}

// Apply (re)starts a camera with its current configuration.
func (m *Manager) Apply(c store.Camera) {
	m.Stop(c.ID)
	if !c.Enabled {
		return
	}
	ctx, cancel := context.WithCancel(m.ctx)
	mode := c.ModeAt(time.Now())
	r := &running{cam: c, cancel: cancel, mode: mode}
	// Motion-only recording records continuously too; footage without motion is
	// removed shortly afterwards by retention (which gives free pre/post buffers).
	recording := mode == "continuous" || mode == "motion"
	mainRec := ""
	if recording {
		mainRec = m.IncomingDir(c.ID, "main")
	}
	r.main = &Stream{CameraID: c.ID, Kind: "main", URL: c.MainURL, Transport: c.Transport, RecordDir: mainRec, Hub: NewHub(), FFmpeg: m.FFmpeg}
	if c.SubURL != "" {
		subRec := ""
		if recording && c.RecordSub {
			subRec = m.IncomingDir(c.ID, "sub")
		}
		r.sub = &Stream{CameraID: c.ID, Kind: "sub", URL: c.SubURL, Transport: c.Transport, RecordDir: subRec, Hub: NewHub(), FFmpeg: m.FFmpeg}
	}
	for _, s := range []*Stream{r.main, r.sub} {
		if s == nil {
			continue
		}
		r.wg.Add(1)
		go func(s *Stream) { defer r.wg.Done(); s.Run(ctx) }(s)
	}
	if c.Motion {
		r.wg.Add(1)
		go func() { defer r.wg.Done(); m.runMotion(ctx, r) }()
	}
	m.mu.Lock()
	m.running[c.ID] = r
	m.mu.Unlock()
	slog.Info("camera started", "id", c.ID, "name", c.Name, "record", mode, "motion", c.Motion)
}

func (m *Manager) Stop(id int64) {
	m.mu.Lock()
	r := m.running[id]
	delete(m.running, id)
	m.mu.Unlock()
	if r != nil {
		r.cancel()
		r.wg.Wait()
		// Index whatever the stopped ffmpeg left behind.
		m.indexCamera(id, true)
	}
}

func (m *Manager) StopAll() {
	m.mu.Lock()
	ids := make([]int64, 0, len(m.running))
	for id := range m.running {
		ids = append(ids, id)
	}
	m.mu.Unlock()
	for _, id := range ids {
		m.Stop(id)
	}
}

// Hub returns the live hub for a camera stream. Asking for "sub" on a camera
// without a substream falls back to the main stream.
func (m *Manager) Hub(id int64, kind string) *Hub {
	m.mu.Lock()
	defer m.mu.Unlock()
	r := m.running[id]
	if r == nil {
		return nil
	}
	if kind == "sub" && r.sub != nil {
		return r.sub.Hub
	}
	return r.main.Hub
}

func (m *Manager) Status(id int64) CameraStatus {
	m.mu.Lock()
	r := m.running[id]
	m.mu.Unlock()
	var cs CameraStatus
	if r == nil {
		return cs
	}
	st := r.main.Status()
	cs.Main = &st
	cs.Motion = r.motion.Load()
	if r.sub != nil {
		st2 := r.sub.Status()
		cs.Sub = &st2
	}
	return cs
}

func (m *Manager) Log(id int64, kind string) []string {
	m.mu.Lock()
	r := m.running[id]
	m.mu.Unlock()
	if r == nil {
		return nil
	}
	if kind == "sub" && r.sub != nil {
		return r.sub.LogTail()
	}
	return r.main.LogTail()
}
