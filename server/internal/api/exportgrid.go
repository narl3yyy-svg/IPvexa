package api

import (
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

const maxGridCameras = 16

// exportGrid streams several cameras' recordings between from and to as one MP4:
// a grid of the cameras, kept in step by wall-clock time, with each camera's name
// and the date and time burnt in. Unlike export, this re-encodes, so it takes
// about as long as the clip on a small server.
//
//	GET /api/export/grid?cameras=1,2,3&from=<ms>&to=<ms>&stream=main|sub
func (s *Server) exportGrid(w http.ResponseWriter, r *http.Request) {
	from, to := queryInt(r, "from", 0), queryInt(r, "to", 0)
	if from <= 0 || to <= from {
		writeErr(w, 400, "choose a start and end time")
		return
	}
	if time.Duration(to-from)*time.Millisecond > maxExport {
		writeErr(w, 400, "clips can be at most 2 hours long")
		return
	}
	p := currentUser(r).Effective()
	if !p.Playback || !p.Export {
		writeErr(w, 403, "your account is not allowed to export video")
		return
	}
	var ids []int64
	for _, f := range strings.Split(r.URL.Query().Get("cameras"), ",") {
		id, err := strconv.ParseInt(strings.TrimSpace(f), 10, 64)
		if err != nil || id <= 0 {
			continue
		}
		dup := false
		for _, x := range ids {
			dup = dup || x == id
		}
		if !dup {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 || len(ids) > maxGridCameras {
		writeErr(w, 400, fmt.Sprintf("choose 1 to %d cameras", maxGridCameras))
		return
	}
	stream, other := "main", "sub"
	if r.URL.Query().Get("stream") == "sub" {
		stream, other = "sub", "main"
	}

	type input struct {
		name  string
		list  string
		first int64
	}
	var inputs []input
	defer func() {
		for _, in := range inputs {
			os.Remove(in.list)
		}
	}()
	for _, id := range ids {
		if !p.CanSee(id) {
			writeErr(w, 404, "camera not found")
			return
		}
		cam, err := s.Store.Camera(id)
		if err != nil {
			writeErr(w, 404, "camera not found")
			return
		}
		// Prefer the chosen stream; fall back to the other one if only that was recorded.
		list, first, err := s.exportList(id, stream, from, to, true)
		if err != nil {
			list, first, err = s.exportList(id, other, from, to, true)
		}
		if err != nil {
			continue // nothing recorded: the cell stays black with the camera's name
		}
		inputs = append(inputs, input{cam.Name, list, first})
	}
	if len(inputs) == 0 {
		writeErr(w, 404, "no recording in that time range")
		return
	}

	// Grid: as square as possible, cells 16:9, at most 1920 wide.
	n := len(inputs)
	cols := int(math.Ceil(math.Sqrt(float64(n))))
	rows := (n + cols - 1) / cols
	cellW := min(640, 1920/cols) &^ 1
	cellH := (cellW * 9 / 16) &^ 1
	const fps = 15
	dur := float64(to-from) / 1000
	text := hasDrawtext(s.FFmpeg)

	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin"}
	for _, in := range inputs {
		args = append(args, "-f", "concat", "-safe", "0", "-i", in.list)
	}
	var g strings.Builder
	for i, in := range inputs {
		// fps fills gaps by repeating the last picture; tpad adds black before the
		// camera's first footage and holds the last picture to the end.
		fmt.Fprintf(&g, "[%d:v]trim=start=0,setpts=PTS-STARTPTS,fps=%d,tpad=start_duration=%.3f:color=black:stop_mode=clone:stop_duration=%.3f,trim=duration=%.3f,"+
			"scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1",
			i, fps, float64(in.first-from)/1000, dur, dur, cellW, cellH, cellW, cellH)
		if text {
			fmt.Fprintf(&g, ",drawtext=text='%s':x=8:y=8:fontsize=%d:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=4",
				drawtextEscape(in.name), max(12, cellH/18))
		}
		fmt.Fprintf(&g, "[c%d];", i)
	}
	if n == 1 {
		g.WriteString("[c0]null[grid]")
	} else {
		var layout []string
		for i := range n {
			layout = append(layout, fmt.Sprintf("%d_%d", i%cols*cellW, i/cols*cellH))
		}
		for i := range n {
			fmt.Fprintf(&g, "[c%d]", i)
		}
		fmt.Fprintf(&g, "xstack=inputs=%d:layout=%s:fill=black[grid]", n, strings.Join(layout, "|"))
	}
	if text {
		// Date and time of each frame, bottom right.
		fmt.Fprintf(&g, ";[grid]drawtext=text='%%{pts\\:localtime\\:%d\\:%%Y-%%m-%%d %%H\\\\\\:%%M\\\\\\:%%S}':x=w-tw-10:y=h-th-10:fontsize=%d:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=5[out]",
			from/1000, max(14, rows*cellH/30))
	} else {
		g.WriteString(";[grid]null[out]")
	}
	args = append(args, "-filter_complex", g.String(), "-map", "[out]", "-t", fmt.Sprintf("%.3f", dur),
		"-c:v", "libx264", "-preset", "veryfast", "-crf", "24", "-pix_fmt", "yuv420p",
		"-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", "pipe:1")

	cmd := exec.CommandContext(r.Context(), s.FFmpeg, args...)
	cmd.WaitDelay = 2 * time.Second
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	name := "IPvexa_" + strconv.Itoa(n) + "_cameras_" + time.UnixMilli(from).Format("2006-01-02_15-04-05") + ".mp4"
	w.Header().Set("Content-Type", "video/mp4")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	w.Header().Set("X-Ipvexa-Filename", name)
	w.WriteHeader(200)
	io.Copy(w, stdout)
	cmd.Wait()
	if msg := strings.TrimSpace(stderr.String()); msg != "" && r.Context().Err() == nil {
		slog.Warn("grid export ffmpeg", "msg", msg)
	}
	var names []string
	for _, in := range inputs {
		names = append(names, in.name)
	}
	s.audit(r, "export", fmt.Sprintf("grid of %s, %s, %s", strings.Join(names, ", "), time.UnixMilli(from).Format(time.DateTime), time.Duration(to-from)*time.Millisecond))
}

// drawtextEscape keeps the letters, digits, spaces and a few safe marks of a camera
// name, so it can't break out of drawtext's text='…' in the filtergraph.
func drawtextEscape(s string) string {
	var b strings.Builder
	for _, c := range s {
		if unicode.IsLetter(c) || unicode.IsDigit(c) || strings.ContainsRune(" -_.#()", c) {
			b.WriteRune(c)
		}
	}
	return b.String()
}

var drawtextOnce struct {
	sync.Once
	ok bool
}

// hasDrawtext reports whether ffmpeg was built with the drawtext filter (it needs
// libfreetype); without it the grid is saved without names and time.
func hasDrawtext(ffmpeg string) bool {
	drawtextOnce.Do(func() {
		out, err := exec.Command(ffmpeg, "-hide_banner", "-filters").Output()
		drawtextOnce.ok = err == nil && strings.Contains(string(out), " drawtext ")
	})
	return drawtextOnce.ok
}
