package api

import "testing"

func TestRedact(t *testing.T) {
	cases := map[string]string{
		"rtsp://admin:p@ss@192.168.1.64:554/cam/realmonitor?channel=1": "rtsp://***@192.168.1.64:554/cam/realmonitor?channel=1",
		"rtsp://192.168.1.64/stream@1":                                 "rtsp://192.168.1.64/stream@1", // '@' in the path is not a login
		"rtsp://user@192.168.1.64/ch0":                                 "rtsp://***@192.168.1.64/ch0",
		"demo://pattern":                                               "demo://pattern",
		"":                                                             "",
	}
	for in, want := range cases {
		if got := redact(in); got != want {
			t.Errorf("redact(%q) = %q, want %q", in, got, want)
		}
	}
}
