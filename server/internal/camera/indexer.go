package camera

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"ipvexa/internal/store"
)

// The indexer moves finished segments out of each stream's incoming/ directory
// into a dated folder and records them in the database. The newest file in
// incoming/ is still being written by ffmpeg and is reported as the "open" segment.

func (m *Manager) runIndexer(ctx context.Context) {
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		m.indexAll()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (m *Manager) indexAll() {
	entries, err := os.ReadDir(m.Root())
	if err != nil {
		return
	}
	for _, e := range entries {
		id, err := strconv.ParseInt(e.Name(), 10, 64)
		if err != nil || !e.IsDir() {
			continue
		}
		m.mu.Lock()
		_, live := m.running[id]
		m.mu.Unlock()
		m.indexCamera(id, !live)
	}
}

// openSegmentIdle is how long the segment being recorded may go unwritten before
// it is treated as finished (ffmpeg gone). It must exceed the longest keyframe
// interval, since ffmpeg writes a fragment per keyframe.
const openSegmentIdle = 3 * time.Minute

type incomingFile struct {
	path  string
	start int64 // unix seconds, from the file name
}

func listIncoming(dir string) []incomingFile {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []incomingFile
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".mp4") {
			continue
		}
		sec, err := strconv.ParseInt(strings.TrimSuffix(name, ".mp4"), 10, 64)
		if err != nil {
			continue
		}
		out = append(out, incomingFile{filepath.Join(dir, name), sec})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].start < out[j].start })
	return out
}

// indexCamera files away finished segments. When stopped is true, ffmpeg is not
// running for this camera, so every file (including the newest) is finished.
func (m *Manager) indexCamera(id int64, stopped bool) {
	m.idxMu.Lock()
	defer m.idxMu.Unlock()
	for _, stream := range []string{"main", "sub"} {
		files := listIncoming(m.IncomingDir(id, stream))
		for i, f := range files {
			newest := i == len(files)-1
			if newest && !stopped {
				// Still being written, unless ffmpeg has clearly stopped touching it.
				// Fragments are only written at keyframes, and some cameras (e.g. with
				// "smart" codecs) send one every 20–30 s, so allow plenty of time.
				if st, err := os.Stat(f.path); err == nil && time.Since(st.ModTime()) < openSegmentIdle {
					continue
				}
			}
			m.finalize(id, stream, f)
		}
	}
}

func (m *Manager) finalize(camID int64, stream string, f incomingFile) {
	st, err := os.Stat(f.path)
	if err != nil {
		return
	}
	dur := m.probeDuration(f.path)
	if dur <= 0 || st.Size() < 1024 {
		slog.Warn("discarding empty/unreadable segment", "path", f.path)
		os.Remove(f.path)
		return
	}
	// Some cameras lower the frame rate in the dark but keep stamping frames at
	// the nominal rate, so the video's own clock runs slow. ffmpeg last wrote the
	// file when the segment ended, which gives its real length; stretch the
	// timestamps to match so playback stays in step with other cameras. Only for
	// video-only (substream) recordings: main recordings carry real-time audio.
	if stream == "sub" {
		real := st.ModTime().Sub(time.Unix(f.start, 0)).Seconds()
		if dur > 5 && real > dur*1.1 && real-dur > 3 && real < 3*60 {
			if err := m.retime(f.path, real/dur); err != nil {
				slog.Warn("could not correct segment timestamps", "path", f.path, "err", err)
			} else if d := m.probeDuration(f.path); d > 0 {
				slog.Debug("corrected slow segment timestamps", "path", f.path, "was", dur, "now", d)
				dur = d
				if st2, err := os.Stat(f.path); err == nil {
					st = st2
				}
			}
		}
	}
	t := time.Unix(f.start, 0).UTC()
	rel := filepath.Join(strconv.FormatInt(camID, 10), stream, t.Format("2006"), t.Format("01"), t.Format("02"), filepath.Base(f.path))
	root := m.Root()
	dst := filepath.Join(root, rel)
	if root != m.RecRoot {
		rel = dst // outside the original folder: store the full path
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o750); err != nil {
		slog.Error("mkdir", "err", err)
		return
	}
	if err := os.Rename(f.path, dst); err != nil {
		slog.Error("move segment", "err", err)
		return
	}
	seg := store.Segment{
		CameraID: camID, Stream: stream, Path: rel,
		Start: f.start * 1000, End: f.start*1000 + int64(dur*1000), Size: st.Size(),
	}
	if err := m.Store.AddSegment(&seg); err != nil {
		slog.Error("index segment", "err", err)
	}
}

// retime rewrites a video-only segment with its timestamps multiplied by k.
func (m *Manager) retime(path string, k float64) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	tmp := path + ".retime" // not .mp4, so the indexer never picks it up
	out, err := exec.CommandContext(ctx, m.FFmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
		"-i", path, "-map", "0:v:0", "-c", "copy", "-bsf:v", fmt.Sprintf("setts=ts=TS*%.6f", k),
		"-f", "mp4", tmp).CombinedOutput()
	if err != nil {
		os.Remove(tmp)
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return os.Rename(tmp, path)
}

func (m *Manager) probeDuration(path string) float64 {
	// A damaged file must not stall indexing for every camera.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, m.FFprobe, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path).Output()
	if err != nil {
		return 0
	}
	d, _ := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	return d
}

// OpenSegment returns the segment ffmpeg is currently writing, if any.
func (m *Manager) OpenSegment(camID int64, stream string) (path string, startMs int64, ok bool) {
	m.mu.Lock()
	_, live := m.running[camID]
	m.mu.Unlock()
	if !live {
		return "", 0, false
	}
	files := listIncoming(m.IncomingDir(camID, stream))
	if len(files) == 0 {
		return "", 0, false
	}
	f := files[len(files)-1]
	st, err := os.Stat(f.path)
	if err != nil || time.Since(st.ModTime()) > openSegmentIdle {
		return "", 0, false
	}
	return f.path, f.start * 1000, true
}
