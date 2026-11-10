// Package timesync keeps the cameras' clocks on the server's time.
//
// The server answers NTP requests itself (cameras usually have no internet access,
// but the server does, or at least is the reference everyone should agree with),
// so cameras can be set to take their time from it, and it checks the cameras'
// clocks regularly over ONVIF, correcting any that have drifted.
package timesync

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"net"
	"sync"
	"time"
)

// ntpEpochOffset is the number of seconds from 1900 (NTP) to 1970 (Unix).
const ntpEpochOffset = 2208988800

func ntpTime(t time.Time) uint64 {
	secs := uint64(t.Unix() + ntpEpochOffset)
	frac := (uint64(t.Nanosecond()) << 32) / 1e9
	return secs<<32 | frac
}

func fromNTP(v uint64) time.Time {
	secs := int64(v>>32) - ntpEpochOffset
	nanos := int64((v & 0xffffffff) * 1e9 >> 32)
	return time.Unix(secs, nanos)
}

// reply builds the answer to an NTP client request (SNTP, RFC 4330), or returns
// nil if the packet isn't a client request.
func reply(req []byte, received, now time.Time, synced bool) []byte {
	if len(req) < 48 {
		return nil
	}
	mode := req[0] & 7
	version := (req[0] >> 3) & 7
	if mode != 3 || version < 1 || version > 4 {
		return nil
	}
	r := make([]byte, 48)
	r[0] = version<<3 | 4 // no leap warning, same version, mode 4 (server)
	r[1] = 3              // stratum: one step below our upstream time server
	if !synced {
		r[1] = 10 // our own clock isn't synchronised: still usable, but ranked low
	}
	r[2] = req[2]                                    // poll interval: as asked
	r[3] = 0xEC                                      // precision: 2^-20 s (about 1 µs)
	binary.BigEndian.PutUint32(r[4:], 0x0000_0100)   // root delay: 1/256 s
	binary.BigEndian.PutUint32(r[8:], 0x0000_0100)   // root dispersion: 1/256 s
	copy(r[12:16], "IPVX")                           // reference ID
	binary.BigEndian.PutUint64(r[16:], ntpTime(now)) // reference time
	copy(r[24:32], req[40:48])                       // originate = the client's transmit time
	binary.BigEndian.PutUint64(r[32:], ntpTime(received))
	binary.BigEndian.PutUint64(r[40:], ntpTime(now)) // transmit time, set last
	return r
}

// NTPServer answers NTP time requests with this machine's clock.
type NTPServer struct {
	Addr    string      // e.g. ":123"
	Enabled func() bool // answer only while this is true (nil = always)

	mu      sync.Mutex
	running bool
	err     string
	served  int
}

// Status says whether the time server is running and, if not, why.
func (s *NTPServer) Status() (running bool, err string, served int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.running, s.err, s.served
}

// Run serves until ctx ends. If the port can't be opened (another time server
// already uses it, or the server lacks permission for port 123) it logs that and
// returns; the cameras' clocks are then still corrected directly (see Syncer).
func (s *NTPServer) Run(ctx context.Context) {
	pc, err := net.ListenPacket("udp", s.Addr)
	if err != nil {
		msg := err.Error()
		if errors.Is(err, net.ErrClosed) {
			msg = "closed"
		}
		s.mu.Lock()
		s.err = msg
		s.mu.Unlock()
		slog.Warn("time server for cameras not started; camera clocks are still corrected directly", "addr", s.Addr, "err", msg)
		return
	}
	s.mu.Lock()
	s.running = true
	s.mu.Unlock()
	slog.Info("time server for cameras running", "addr", s.Addr)
	go func() { <-ctx.Done(); pc.Close() }()
	buf := make([]byte, 512)
	for {
		n, from, err := pc.ReadFrom(buf)
		if err != nil {
			if ctx.Err() != nil {
				s.mu.Lock()
				s.running = false
				s.mu.Unlock()
				return
			}
			continue
		}
		received := time.Now()
		if s.Enabled != nil && !s.Enabled() {
			continue
		}
		if out := reply(buf[:n], received, time.Now(), clockSynced()); out != nil {
			pc.WriteTo(out, from)
			s.mu.Lock()
			s.served++
			s.mu.Unlock()
		}
	}
}
