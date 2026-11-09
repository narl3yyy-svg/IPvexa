package camera

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Stream supervises one ffmpeg process for one camera stream (main or sub).
// ffmpeg pulls the camera once and writes two outputs without re-encoding:
//   - an MPEG-TS pipe that feeds the live Hub, and
//   - optionally, 1-minute fragmented-MP4 recording segments.
type Stream struct {
	CameraID  int64
	Kind      string // "main" | "sub"
	URL       string
	Transport string
	RecordDir string // empty = don't record
	// OnDemand streams only connect to the camera while someone is watching
	// (saves camera and Wi-Fi bandwidth for main streams that aren't recorded).
	OnDemand bool
	Hub      *Hub
	FFmpeg   string
	log      *slog.Logger

	mu      sync.Mutex
	status  StreamStatus
	logTail []string
}

type StreamStatus struct {
	State      string  `json:"state"` // starting | online | offline | idle (on demand, unwatched) | stopped
	Codec      string  `json:"codec,omitempty"`
	Width      int     `json:"width,omitempty"`
	Height     int     `json:"height,omitempty"`
	FPS        float64 `json:"fps,omitempty"`
	BitrateBps float64 `json:"bitrate_bps"`
	LastError  string  `json:"last_error,omitempty"`
	Since      int64   `json:"since"`
	Restarts   int     `json:"restarts"`
	Viewers    int     `json:"viewers"`
	Recording  bool    `json:"recording"`
}

// Greedy up to the last '@' before the path: passwords may contain '@'.
var loginRe = regexp.MustCompile(`([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s'"]+@`)

// HideLogins replaces "user:password@" in any URL in s with "***@".
func HideLogins(s string) string { return loginRe.ReplaceAllString(s, "${1}***@") }

var videoInfoRe = regexp.MustCompile(`Stream #0:\d+.*?: Video: (\w+)[^,]*,.*?(\d{2,5})x(\d{2,5})[^,]*(?:,.*?([\d.]+) fps)?`)

func (s *Stream) Status() StreamStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := s.status
	st.Viewers = s.Hub.Viewers()
	return st
}

func (s *Stream) LogTail() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.logTail...)
}

func (s *Stream) setState(state, errMsg string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.status.State != state {
		s.status.Since = time.Now().UnixMilli()
	}
	s.status.State = state
	if errMsg != "" {
		s.status.LastError = errMsg
	}
}

// Args builds the ffmpeg command line. Exported for tests and diagnostics.
func (s *Stream) Args() []string {
	// -nostats: no progress lines (they end in \r, not \n, and only add load on the log pipe).
	a := []string{"-hide_banner", "-nostdin", "-nostats", "-loglevel", "info"}
	demo := strings.HasPrefix(s.URL, "demo://")
	switch {
	case demo:
		size := "1280x720"
		if s.Kind == "sub" {
			size = "640x360"
		}
		a = append(a, "-re", "-f", "lavfi", "-i", "testsrc2=size="+size+":rate=15")
	case strings.HasPrefix(s.URL, "rtsp://") || strings.HasPrefix(s.URL, "rtsps://"):
		tr := s.Transport
		if tr == "" {
			tr = "tcp"
		}
		// nobuffer/low_delay: hand packets on as soon as they arrive (lower live latency).
		a = append(a, "-rtsp_transport", tr, "-timeout", "10000000", "-fflags", "+genpts+discardcorrupt+nobuffer", "-flags", "low_delay", "-i", s.URL)
	default:
		a = append(a, "-fflags", "+genpts+discardcorrupt+nobuffer", "-flags", "low_delay", "-rw_timeout", "10000000", "-i", s.URL)
	}

	vcodec := []string{"-c:v", "copy"}
	if demo {
		vcodec = []string{"-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-g", "15", "-pix_fmt", "yuv420p"}
	}

	// Output 1: live MPEG-TS on stdout. Parameter sets are repeated on every
	// keyframe so viewers can join at any time.
	a = append(a, "-map", "0:v:0")
	a = append(a, vcodec...)
	if !demo {
		a = append(a, "-bsf:v", "dump_extra=freq=keyframe")
	}
	a = append(a, "-f", "mpegts", "-muxdelay", "0", "-muxpreload", "0", "-flush_packets", "1", "pipe:1")

	// Output 2: recording segments. Audio (often G.711 on cameras) is converted to AAC
	// so it fits in MP4; video is copied untouched.
	if s.RecordDir != "" {
		a = append(a, "-map", "0:v:0", "-map", "0:a:0?")
		a = append(a, vcodec...)
		a = append(a, "-c:a", "aac", "-b:a", "64k",
			"-f", "segment", "-segment_time", "60", "-segment_atclocktime", "1",
			"-reset_timestamps", "1", "-strftime", "1", "-segment_format", "mp4",
			"-segment_format_options", "movflags=+frag_keyframe+empty_moov+default_base_moof",
			filepath.Join(s.RecordDir, "%s.mp4"))
	}
	return a
}

// Run keeps ffmpeg running until ctx is cancelled, reconnecting with backoff.
func (s *Stream) Run(ctx context.Context) {
	s.log = slog.With("camera", s.CameraID, "stream", s.Kind)
	backoff := time.Second
	for ctx.Err() == nil {
		if s.OnDemand && s.Hub.Viewers() == 0 {
			s.setState("idle", "")
			select {
			case <-ctx.Done():
				continue
			case <-s.Hub.Wake():
			}
			if s.Hub.Viewers() == 0 {
				continue
			}
		}
		if s.RecordDir != "" {
			if err := os.MkdirAll(s.RecordDir, 0o750); err != nil {
				s.setState("offline", "cannot create recording dir: "+err.Error())
			}
		}
		s.setState("starting", "")
		start := time.Now()
		runCtx, stopRun := context.WithCancel(ctx)
		if s.OnDemand {
			go s.stopWhenUnwatched(runCtx, stopRun)
		}
		err := s.runOnce(runCtx)
		stopRun()
		if ctx.Err() != nil {
			break
		}
		if s.OnDemand && runCtx.Err() != nil && s.Hub.Viewers() == 0 {
			backoff = time.Second // stopped because nobody is watching: not an error
			continue
		}
		msg := "ffmpeg exited"
		if err != nil {
			msg = err.Error()
		}
		if tail := s.LogTail(); len(tail) > 0 {
			msg = tail[len(tail)-1]
		}
		s.setState("offline", msg)
		s.mu.Lock()
		s.status.Restarts++
		s.mu.Unlock()
		s.log.Warn("stream stopped, retrying", "err", msg, "in", backoff)
		if time.Since(start) > time.Minute {
			backoff = time.Second
		}
		select {
		case <-ctx.Done():
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 30*time.Second)
	}
	s.setState("stopped", "")
}

// stopWhenUnwatched ends an on-demand session after 20 s without viewers.
func (s *Stream) stopWhenUnwatched(ctx context.Context, stop context.CancelFunc) {
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	idle := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if s.Hub.Viewers() > 0 {
			idle = 0
			continue
		}
		if idle++; idle >= 4 {
			stop()
			return
		}
	}
}

func (s *Stream) runOnce(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, s.FFmpeg, s.Args()...)
	cmd.WaitDelay = 5 * time.Second
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	s.Hub.Reset()
	if err := cmd.Start(); err != nil {
		return err
	}
	s.mu.Lock()
	s.status.Recording = s.RecordDir != ""
	s.status.LastError = ""
	s.mu.Unlock()

	go s.readLog(stderr)

	// Bitrate meter + online detection.
	done := make(chan struct{})
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		last := s.Hub.BytesIn()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				now := s.Hub.BytesIn()
				bps := float64(now-last) * 8 / 2
				last = now
				s.mu.Lock()
				s.status.BitrateBps = bps
				s.mu.Unlock()
				if bps > 0 {
					s.setState("online", "")
				}
			}
		}
	}()

	_, copyErr := io.CopyBuffer(s.Hub, stdout, make([]byte, 64*1024))
	close(done)
	waitErr := cmd.Wait()
	if copyErr != nil {
		return copyErr
	}
	return waitErr
}

func (s *Stream) readLog(r io.Reader) {
	// If ffmpeg's log pipe ever fills up, ffmpeg blocks and stops reading the camera,
	// so keep draining it whatever happens to the line parsing.
	defer io.Copy(io.Discard, r)
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	sc.Split(scanLogLines)
	for sc.Scan() {
		// ffmpeg puts the input URL in some errors; never keep camera passwords.
		line := HideLogins(sc.Text())
		if line == "" {
			continue
		}
		if m := videoInfoRe.FindStringSubmatch(line); m != nil {
			s.mu.Lock()
			s.status.Codec = m[1]
			fmt.Sscan(m[2], &s.status.Width)
			fmt.Sscan(m[3], &s.status.Height)
			if m[4] != "" {
				fmt.Sscan(m[4], &s.status.FPS)
			}
			s.mu.Unlock()
		}
		s.mu.Lock()
		s.logTail = append(s.logTail, line)
		if len(s.logTail) > 40 {
			s.logTail = s.logTail[len(s.logTail)-40:]
		}
		s.mu.Unlock()
	}
}

// scanLogLines splits ffmpeg's log on \n and on \r (ffmpeg uses \r for lines it rewrites).
func scanLogLines(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if atEOF && len(data) == 0 {
		return 0, nil, nil
	}
	if i := bytes.IndexAny(data, "\r\n"); i >= 0 {
		return i + 1, data[:i], nil
	}
	if atEOF {
		return len(data), data, nil
	}
	return 0, nil, nil
}
