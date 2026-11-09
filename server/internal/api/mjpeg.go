package api

import (
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Browser video for the web/phone view.
//
//	GET /api/cameras/{id}/mjpeg   multipart JPEG: works in every browser in an <img>
//	GET /api/cameras/{id}/fmp4    fragmented MP4 for <video>: full frame rate and
//	                              quality, no re-encoding (H.264 everywhere; H.265
//	                              only where the browser supports it)
//
// Both take ?t=<ms> for the recording from that moment (sent in real time);
// without it they stream live. mjpeg also takes &w=<width> and &fps=<1-15>.
func (s *Server) mjpeg(w http.ResponseWriter, r *http.Request) {
	width := min(max(queryInt(r, "w", 640), 160), 1280)
	fps := min(max(queryInt(r, "fps", 6), 1), 15)
	s.browserStream(w, r, "sub", []string{"-an", "-sn", "-threads", "1",
		"-vf", fmt.Sprintf("fps=%d,scale='min(%d,iw)':-2", fps, width),
		"-q:v", "7", "-f", "mpjpeg", "-boundary_tag", "ipvexa", "pipe:1"},
		"multipart/x-mixed-replace;boundary=ipvexa")
}

func (s *Server) fmp4(w http.ResponseWriter, r *http.Request) {
	stream := "main"
	if r.URL.Query().Get("stream") == "sub" {
		stream = "sub"
	}
	id, _ := pathID(r)
	out := []string{"-map", "0:v:0", "-c:v", "copy"}
	// Browsers want H.265 in MP4 tagged "hvc1".
	if st := s.Cams.Status(id); (stream == "main" && st.Main != nil && st.Main.Codec == "hevc") ||
		(stream == "sub" && st.Sub != nil && st.Sub.Codec == "hevc") {
		out = append(out, "-tag:v", "hvc1")
	}
	out = append(out, "-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", "pipe:1")
	s.browserStream(w, r, stream, out, "video/mp4")
}

// browserStream runs ffmpeg on a camera's live hub (or its recording from ?t=)
// with the given output arguments and copies the result to the response.
func (s *Server) browserStream(w http.ResponseWriter, r *http.Request, stream string, out []string, contentType string) {
	id, _ := pathID(r)
	t := queryInt(r, "t", 0)
	var cmd *exec.Cmd
	if t > 0 {
		if !currentUser(r).Effective().Playback {
			writeErr(w, 403, "your account is not allowed to view recordings")
			return
		}
		list, startWall, err := s.concatFrom(id, "main", t)
		if err != nil {
			writeErr(w, 404, err.Error())
			return
		}
		defer os.Remove(list)
		w.Header().Set("X-Ipvexa-Start", strconv.FormatInt(startWall, 10))
		args := append([]string{"-hide_banner", "-loglevel", "error", "-nostdin", "-re",
			"-f", "concat", "-safe", "0", "-i", list}, out...)
		cmd = exec.CommandContext(r.Context(), s.FFmpeg, args...)
	} else {
		hub := s.Cams.Hub(id, stream)
		if hub == nil {
			writeErr(w, 404, "camera not running")
			return
		}
		sub := hub.Subscribe()
		defer sub.Close()
		args := append([]string{"-hide_banner", "-loglevel", "error", "-nostdin", hubInput[0], hubInput[1], hubInput[2], hubInput[3],
			"-fflags", "+genpts+discardcorrupt+nobuffer", "-f", "mpegts", "-i", "pipe:0"}, out...)
		cmd = exec.CommandContext(r.Context(), s.FFmpeg, args...)
		stdin, err := cmd.StdinPipe()
		if err != nil {
			writeErr(w, 500, err.Error())
			return
		}
		go func() {
			defer stdin.Close()
			for {
				select {
				case <-r.Context().Done():
					return
				case b, ok := <-sub.C:
					if !ok {
						return
					}
					if _, err := stdin.Write(b); err != nil {
						return
					}
				}
			}
		}()
	}
	cmd.WaitDelay = 2 * time.Second
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	if err := cmd.Start(); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(200)
	fl, _ := w.(http.Flusher)
	buf := make([]byte, 32*1024)
	for {
		n, err := stdout.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				break
			}
			if fl != nil {
				fl.Flush()
			}
		}
		if err != nil { // EOF or the viewer left
			break
		}
	}
	cmd.Wait()
}

// concatFrom writes an ffconcat list of the continuous recording that starts at
// (or after) t, and returns its path and the wall time of its first frame.
func (s *Server) concatFrom(id int64, stream string, t int64) (string, int64, error) {
	segs, err := s.Store.Segments(id, stream, t, t+6*3600*1000)
	if err != nil {
		return "", 0, err
	}
	type part struct {
		path       string
		start, end int64
	}
	var run []part
	for _, g := range segs {
		if n := len(run); n > 0 && g.Start-run[n-1].end > gapTolerance {
			break
		}
		run = append(run, part{g.File(s.RecRoot), g.Start, g.End})
	}
	if p, start, ok := s.Cams.OpenSegment(id, stream); ok {
		n := len(run)
		if (n == 0 && start <= t+gapTolerance) || (n > 0 && start-run[n-1].end <= gapTolerance) || (n == 0 && start > t) {
			run = append(run, part{p, start, 0})
		}
	}
	if len(run) == 0 {
		return "", 0, fmt.Errorf("no recording at or after this time")
	}
	startWall := max(t, run[0].start)
	var list strings.Builder
	list.WriteString("ffconcat version 1.0\n")
	for i, p := range run {
		fmt.Fprintf(&list, "file '%s'\n", strings.ReplaceAll(p.path, "'", `'\''`))
		if i == 0 && startWall > p.start {
			fmt.Fprintf(&list, "inpoint %.3f\n", float64(startWall-p.start)/1000)
		}
		if p.end > 0 {
			fmt.Fprintf(&list, "duration %.3f\n", float64(p.end-p.start)/1000)
		}
	}
	tmp, err := os.CreateTemp("", "ipvexa-mjpeg-*.ffconcat")
	if err != nil {
		return "", 0, err
	}
	tmp.WriteString(list.String())
	tmp.Close()
	return tmp.Name(), startWall, nil
}
