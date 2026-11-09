package camera

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"time"

	"ipvexa/internal/motion"
	"ipvexa/internal/store"
)

// Analysis rate. A few frames per second is plenty to catch people and cars and
// keeps CPU use low (the substream is small, so decoding it is cheap).
const motionFPS = 5

// runMotion analyses the camera's live stream (the substream when there is one)
// until ctx ends, restarting the analyser if it stops.
func (m *Manager) runMotion(ctx context.Context, r *running) {
	hub := r.main.Hub
	if r.sub != nil {
		hub = r.sub.Hub
	}
	det := &motion.Detector{Sensitivity: r.cam.MotionSensitivity, Mask: motion.ParseCells(r.cam.MotionMask)}
	tr := &motion.Tracker{}
	var openID int64
	finish := func(e *motion.Event) {
		if e == nil || openID == 0 {
			return
		}
		m.Store.FinishEvent(openID, e.End, e.Cells.String(), e.Peak)
		ev := store.Event{ID: openID, CameraID: r.cam.ID, Kind: "motion", Start: e.Start, End: e.End, Cells: e.Cells.String(), Level: e.Peak}
		openID = 0
		r.motion.Store(false)
		m.emit(ev, false)
	}
	defer func() { finish(tr.Flush()) }()

	// Debug statistics, logged once a minute.
	frames, peak, statAt := 0, 0.0, time.Now()
	gpu := m.GPU
	for ctx.Err() == nil {
		got := 0
		err := m.analyse(ctx, hub, gpu, func(frame []byte) {
			got++
			now := time.Now().UnixMilli()
			res := det.Feed(frame)
			frames++
			peak = max(peak, res.Level)
			if time.Since(statAt) >= time.Minute {
				slog.Debug("motion analyser", "camera", r.cam.ID, "frames", frames, "peak_level", peak)
				frames, peak, statAt = 0, 0, time.Now()
			}
			started, ended := tr.Update(now, res)
			if ended != nil {
				finish(ended)
			}
			if started != nil {
				ev := store.Event{CameraID: r.cam.ID, Kind: "motion", Start: started.Start, Cells: started.Cells.String(), Level: started.Peak}
				if err := m.Store.AddEvent(&ev); err != nil {
					slog.Warn("motion: save event", "camera", r.cam.ID, "err", err)
					return
				}
				openID = ev.ID
				r.motion.Store(true)
				m.emit(ev, true)
			}
		})
		// The stream stopped or restarted: close any open event, then retry.
		finish(tr.Flush())
		if gpu && got == 0 && ctx.Err() == nil {
			// e.g. a codec or size the GPU can't decode: use the CPU for this camera.
			slog.Warn("motion: GPU decoding gave no frames, using the CPU", "camera", r.cam.ID, "err", err)
			gpu = false
			continue
		}
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			slog.Debug("motion analyser stopped", "camera", r.cam.ID, "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(3 * time.Second):
		}
	}
}

// motionArgs returns the ffmpeg arguments that turn an MPEG-TS stream on stdin into
// small greyscale frames on stdout. With gpu, the NVIDIA GPU decodes the video and
// drops the frames that aren't analysed; only the analysed ones are copied back for
// the (tiny) final resize. Decoding is the costly part, especially without a
// substream, when the full-resolution stream is analysed.
func motionArgs(gpu bool) []string {
	a := []string{"-hide_banner", "-loglevel", "error", "-nostdin"}
	vf := fmt.Sprintf("fps=%d,scale=%d:%d:flags=area,format=gray", motionFPS, motion.W, motion.H)
	if gpu {
		a = append(a, "-hwaccel", "cuda", "-hwaccel_output_format", "cuda")
		vf = fmt.Sprintf("fps=%d,hwdownload,format=nv12|p010le,scale=%d:%d:flags=area,format=gray", motionFPS, motion.W, motion.H)
	}
	return append(a, "-probesize", "1000000", "-analyzeduration", "500000",
		"-fflags", "+genpts+discardcorrupt", "-f", "mpegts", "-i", "pipe:0",
		"-an", "-sn", "-threads", "1", "-vf", vf, "-f", "rawvideo", "pipe:1")
}

// analyse decodes the hub's stream into small greyscale frames and calls fn for each.
func (m *Manager) analyse(ctx context.Context, hub *Hub, gpu bool, fn func([]byte)) error {
	sub := hub.Subscribe()
	defer sub.Close()

	actx, cancel := context.WithCancel(ctx)
	defer cancel()
	cmd := exec.CommandContext(actx, m.FFmpeg, motionArgs(gpu)...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	// Feed the live stream to ffmpeg; stop when the stream ends or we're cancelled.
	go func() {
		defer stdin.Close()
		for {
			select {
			case <-actx.Done():
				return
			case chunk, ok := <-sub.C:
				if !ok {
					cancel()
					return
				}
				if _, err := stdin.Write(chunk); err != nil {
					return
				}
			}
		}
	}()
	buf := make([]byte, motion.W*motion.H)
	var readErr error
	for {
		if _, readErr = io.ReadFull(stdout, buf); readErr != nil {
			break
		}
		fn(buf)
	}
	cancel()
	cmd.Wait()
	return readErr
}

// DetectGPU reports whether ffmpeg can use an NVIDIA GPU (NVDEC) for decoding.
// Set IPVEXA_NO_HWDEC=1 to always use the CPU.
func DetectGPU(ffmpeg string) bool {
	if os.Getenv("IPVEXA_NO_HWDEC") != "" {
		return false
	}
	if _, err := os.Stat("/dev/nvidiactl"); err != nil {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	err := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
		"-init_hw_device", "cuda=gpu", "-f", "lavfi", "-i", "color=s=64x64", "-frames:v", "1", "-f", "null", "-").Run()
	return err == nil
}

// emit passes an event to the listener (notifications), if any.
func (m *Manager) emit(e store.Event, started bool) {
	if m.OnEvent != nil {
		m.OnEvent(e, started)
	}
}
