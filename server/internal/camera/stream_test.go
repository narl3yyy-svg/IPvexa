package camera

import "testing"

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
