package camera

import (
	"context"
	"log/slog"
	"path/filepath"
	"strconv"
	"sync"

	"ipvexa/internal/store"
)

// Manager owns the running streams for every enabled camera.
type Manager struct {
	Store   *store.Store
	RecRoot string
	FFmpeg  string
	FFprobe string

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
}

type CameraStatus struct {
	Main *StreamStatus `json:"main,omitempty"`
	Sub  *StreamStatus `json:"sub,omitempty"`
}

func (m *Manager) Start(ctx context.Context) error {
	m.ctx = ctx
	m.running = map[int64]*running{}
	cams, err := m.Store.Cameras()
	if err != nil {
		return err
	}
	for _, c := range cams {
		m.Apply(c)
	}
	go m.runIndexer(ctx)
	return nil
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
	r := &running{cam: c, cancel: cancel}
	mainRec := ""
	if c.RecordMode == "continuous" {
		mainRec = m.IncomingDir(c.ID, "main")
	}
	r.main = &Stream{CameraID: c.ID, Kind: "main", URL: c.MainURL, Transport: c.Transport, RecordDir: mainRec, Hub: NewHub(), FFmpeg: m.FFmpeg}
	if c.SubURL != "" {
		subRec := ""
		if c.RecordMode == "continuous" && c.RecordSub {
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
	m.mu.Lock()
	m.running[c.ID] = r
	m.mu.Unlock()
	slog.Info("camera started", "id", c.ID, "name", c.Name, "record", c.RecordMode)
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
