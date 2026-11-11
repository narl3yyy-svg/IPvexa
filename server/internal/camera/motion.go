package camera

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"time"

	"ipvexa/internal/ai"
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

	// With the object detector, motion is checked for people, vehicles and animals:
	// with a filter set, an event only counts once a wanted object moves.
	gate := newObjectGate(m.AI, r.cam.MotionObjects)
	aiSize := 0
	if gate != nil {
		aiSize = m.AI.Size()
		go gate.run(ctx)
	} else if r.cam.MotionObjects != "" {
		slog.Warn("motion: object detection isn't available, so all motion counts", "camera", r.cam.ID, "wanted", r.cam.MotionObjects)
	}

	var openID int64
	var pending *motion.Event // motion waiting for a wanted object
	open := func(e motion.Event) {
		ev := store.Event{CameraID: r.cam.ID, Kind: "motion", Start: e.Start, Cells: e.Cells.String(), Level: e.Peak, Objects: gate.objects()}
		if err := m.Store.AddEvent(&ev); err != nil {
			slog.Warn("motion: save event", "camera", r.cam.ID, "err", err)
			return
		}
		openID = ev.ID
		r.motion.Store(true)
		m.emit(ev, true)
	}
	finish := func(e *motion.Event) {
		if e == nil {
			return
		}
		objects := gate.end()
		if pending != nil {
			slog.Debug("motion ignored: no wanted object moved", "camera", r.cam.ID, "wanted", r.cam.MotionObjects, "seen", objects)
			pending = nil
			return
		}
		if openID == 0 {
			return
		}
		m.Store.FinishEvent(openID, e.End, e.Cells.String(), e.Peak, objects)
		ev := store.Event{ID: openID, CameraID: r.cam.ID, Kind: "motion", Start: e.Start, End: e.End, Cells: e.Cells.String(), Level: e.Peak, Objects: objects}
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
		err := m.analyse(ctx, hub, gpu, aiSize, gate.setFrame, func(frame []byte) {
			got++
			now := time.Now().UnixMilli()
			res := det.Feed(frame)
			frames++
			peak = max(peak, res.Level)
			if time.Since(statAt) >= time.Minute {
				slog.Debug("motion analyser", "camera", r.cam.ID, "frames", frames, "peak_level", peak)
				frames, peak, statAt = 0, 0, time.Now()
			}
			gate.addMotion(now, res.Cells)
			started, ended := tr.Update(now, res)
			if ended != nil {
				finish(ended)
			}
			if started != nil {
				gate.begin()
				if gate.filtering() {
					pending = started
				} else {
					open(*started)
				}
			}
			if pending != nil && gate.isMatched() {
				e := *pending
				pending = nil
				open(e)
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
//
// With aiSize > 0, the same decoded video also gives a few colour pictures a
// second, scaled to fit in aiSize×aiSize, for the object detector: PAM pictures
// on file descriptor 3.
func motionArgs(gpu bool, aiSize int) []string {
	a := []string{"-hide_banner", "-loglevel", "error", "-nostdin"}
	pre := fmt.Sprintf("fps=%d", motionFPS)
	if gpu {
		a = append(a, "-hwaccel", "cuda", "-hwaccel_output_format", "cuda")
		pre += ",hwdownload,format=nv12|p010le"
	}
	a = append(a, "-probesize", "1000000", "-analyzeduration", "500000",
		"-fflags", "+genpts+discardcorrupt", "-f", "mpegts", "-i", "pipe:0")
	grey := fmt.Sprintf("scale=%d:%d:flags=area,format=gray", motion.W, motion.H)
	if aiSize <= 0 {
		return append(a, "-an", "-sn", "-threads", "1", "-vf", pre+","+grey, "-f", "rawvideo", "pipe:1")
	}
	graph := strings.Join([]string{
		"[0:v]" + pre + ",split=2[m][d]",
		"[m]" + grey + "[mo]",
		fmt.Sprintf("[d]fps=%d,scale=%d:%d:force_original_aspect_ratio=decrease:flags=bilinear,format=rgb24[do]", aiFPS, aiSize, aiSize),
	}, ";")
	return append(a, "-filter_complex_threads", "1", "-filter_complex", graph,
		"-map", "[mo]", "-an", "-sn", "-threads", "1", "-f", "rawvideo", "pipe:1",
		"-map", "[do]", "-an", "-sn", "-threads", "1", "-f", "image2pipe", "-c:v", "pam", "pipe:3")
}

// analyse decodes the hub's stream into small greyscale frames and calls fn for
// each. With aiSize > 0 it also passes colour pictures to pic (see motionArgs).
func (m *Manager) analyse(ctx context.Context, hub *Hub, gpu bool, aiSize int, pic func(ai.Frame), fn func([]byte)) error {
	sub := hub.Subscribe()
	defer sub.Close()

	actx, cancel := context.WithCancel(ctx)
	defer cancel()
	cmd := exec.CommandContext(actx, m.FFmpeg, motionArgs(gpu, aiSize)...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var picR, picW *os.File
	if aiSize > 0 {
		if picR, picW, err = os.Pipe(); err != nil {
			return err
		}
		defer picR.Close()
		cmd.ExtraFiles = []*os.File{picW} // ffmpeg's pipe:3
	}
	err = cmd.Start()
	if picW != nil {
		picW.Close() // ffmpeg has its own copy
	}
	if err != nil {
		return err
	}
	if picR != nil {
		go func() {
			br := bufio.NewReaderSize(picR, 1<<20)
			for {
				f, err := readPAM(br)
				if err != nil {
					cancel() // the two outputs belong together: restart both
					return
				}
				pic(f)
			}
		}()
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
