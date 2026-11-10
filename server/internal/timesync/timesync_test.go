package timesync

import (
	"context"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

func TestNTPTimeRoundTrip(t *testing.T) {
	now := time.Date(2026, 11, 9, 17, 3, 40, 123456789, time.UTC)
	if got := fromNTP(ntpTime(now)); got.Sub(now).Abs() > time.Microsecond {
		t.Errorf("round trip: %v", got)
	}
}

func TestReplyIgnoresNonClients(t *testing.T) {
	req := make([]byte, 48)
	req[0] = 4<<3 | 4 // a server packet
	if reply(req, time.Now(), time.Now(), true) != nil {
		t.Error("answered a non-client packet")
	}
	if reply(make([]byte, 20), time.Now(), time.Now(), true) != nil {
		t.Error("answered a short packet")
	}
}

// A real NTP query over UDP, the way a camera asks: the answer must echo the
// request's transmit time and carry our clock.
func TestServerAnswersQuery(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pc, _ := net.ListenPacket("udp", "127.0.0.1:0")
	addr := pc.LocalAddr().String()
	pc.Close()
	srv := &NTPServer{Addr: addr}
	go srv.Run(ctx)
	time.Sleep(100 * time.Millisecond)

	conn, err := net.Dial("udp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	req := make([]byte, 48)
	req[0] = 4<<3 | 3 // version 4, client
	sent := time.Now()
	binary.BigEndian.PutUint64(req[40:], ntpTime(sent))
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	conn.Write(req)
	resp := make([]byte, 64)
	n, err := conn.Read(resp)
	if err != nil || n != 48 {
		t.Fatalf("no answer: %v (%d bytes)", err, n)
	}
	if resp[0]&7 != 4 || resp[1] == 0 || resp[1] >= 16 {
		t.Errorf("bad header: mode %d stratum %d", resp[0]&7, resp[1])
	}
	if string(resp[24:32]) != string(req[40:48]) {
		t.Error("originate time is not the request's transmit time")
	}
	if tx := fromNTP(binary.BigEndian.Uint64(resp[40:])); tx.Sub(sent).Abs() > time.Second {
		t.Errorf("server time %v, expected about %v", tx, sent)
	}
	if running, _, served := srv.Status(); !running || served != 1 {
		t.Errorf("status running=%v served=%d", running, served)
	}
}

func TestPortInUseIsReported(t *testing.T) {
	pc, _ := net.ListenPacket("udp", "127.0.0.1:0")
	defer pc.Close()
	srv := &NTPServer{Addr: pc.LocalAddr().String()}
	srv.Run(context.Background()) // returns at once
	if running, msg, _ := srv.Status(); running || msg == "" {
		t.Errorf("running=%v err=%q", running, msg)
	}
}
