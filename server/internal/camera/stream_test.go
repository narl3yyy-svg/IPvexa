package camera

import (
	"strings"
	"testing"
)

func TestHideLogins(t *testing.T) {
	in := "[in#0 @ 0x1] Error opening input: rtsp://admin:s3cr%40t@192.168.1.64:554/cam/realmonitor?channel=1: Connection timed out"
	want := "[in#0 @ 0x1] Error opening input: rtsp://***@192.168.1.64:554/cam/realmonitor?channel=1: Connection timed out"
	if got := HideLogins(in); got != want {
		t.Errorf("got %q", got)
	}
	if got := HideLogins("rtsp://admin:p@ss@192.168.1.64/ch0 failed"); got != "rtsp://***@192.168.1.64/ch0 failed" {
		t.Errorf("unencoded @ in password: %q", got)
	}
	if got := HideLogins("Stream #0:0: Video: h264"); got != "Stream #0:0: Video: h264" {
		t.Errorf("changed a line without a URL: %q", got)
	}
}

func TestScanLogLines(t *testing.T) {
	data := []byte("one\rtwo\r\nthree")
	var got []string
	for len(data) > 0 {
		adv, tok, _ := scanLogLines(data, true)
		got = append(got, string(tok))
		data = data[adv:]
	}
	want := []string{"one", "two", "", "three"}
	if len(got) != len(want) {
		t.Fatalf("got %q", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %q, want %q", got, want)
		}
	}
}

// Substream recordings are video only: a camera that announces audio on its
// substream but never sends any would otherwise block the recording.
func TestRecordingAudio(t *testing.T) {
	has := func(args []string, v string) bool {
		for _, a := range args {
			if a == v {
				return true
			}
		}
		return false
	}
	main := &Stream{Kind: "main", URL: "rtsp://192.168.1.64/main", RecordDir: "/rec", RecordAudio: true}
	sub := &Stream{Kind: "sub", URL: "rtsp://192.168.1.64/sub", RecordDir: "/rec"}
	if !has(main.Args(), "0:a:0?") || !has(main.Args(), "aac") {
		t.Error("main recordings should keep the audio")
	}
	if has(sub.Args(), "0:a:0?") || has(sub.Args(), "aac") {
		t.Error("substream recordings should not map audio")
	}
}

func TestMotionArgsGPU(t *testing.T) {
	cpu := strings.Join(motionArgs(false), " ")
	gpu := strings.Join(motionArgs(true), " ")
	if strings.Contains(cpu, "cuda") {
		t.Error("CPU analyser must not ask for the GPU")
	}
	// The hardware options must come before the input, and frames are dropped
	// (fps) before they are copied back from the GPU.
	if !strings.Contains(gpu, "-hwaccel cuda -hwaccel_output_format cuda") ||
		strings.Index(gpu, "-hwaccel") > strings.Index(gpu, "-i pipe:0") ||
		strings.Index(gpu, "fps=") > strings.Index(gpu, "hwdownload") {
		t.Errorf("GPU args: %s", gpu)
	}
}
