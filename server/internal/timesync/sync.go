package timesync

import (
	"context"
	"log/slog"
	"net"
	"strconv"
	"sync"
	"time"

	"ipvexa/internal/onvif"
	"ipvexa/internal/store"
)

// CameraClock is what the server knows about one camera's clock.
type CameraClock struct {
	OffsetMs  int64  `json:"offset_ms"`            // camera clock minus server clock (±500 ms)
	CheckedAt int64  `json:"checked_at"`           // unix ms
	NTPServer string `json:"ntp_server,omitempty"` // the NTP server the camera uses, if known
	UsesUs    bool   `json:"uses_server"`          // its NTP server is this server
	Corrected int64  `json:"corrected_at,omitempty"`
	Error     string `json:"error,omitempty"`
}

// Target gives a camera's host, ONVIF port and login.
type Target func(c store.Camera) (host string, port int, user, pass string, err error)

// Syncer checks every camera's clock regularly and sets any camera more than
// MaxOffset off to the server's time. Cameras set to use this server for NTP
// (in their own settings) stay in step between checks.
type Syncer struct {
	Store     *store.Store
	Target    Target
	Enabled   func() bool
	NTP       *NTPServer    // optional: the server's own time service
	Every     time.Duration // default 30 min
	MaxOffset time.Duration // default 2 s

	mu     sync.Mutex
	clocks map[int64]CameraClock
	kick   chan struct{}
}

// Status returns the last check of a camera's clock, if any.
func (s *Syncer) Status(id int64) *CameraClock {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c, ok := s.clocks[id]; ok {
		return &c
	}
	return nil
}

// Kick runs a check soon (e.g. after the setting was switched on).
func (s *Syncer) Kick() {
	s.mu.Lock()
	if s.kick == nil {
		s.kick = make(chan struct{}, 1)
	}
	k := s.kick
	s.mu.Unlock()
	select {
	case k <- struct{}{}:
	default:
	}
}

func (s *Syncer) Run(ctx context.Context) {
	s.mu.Lock()
	if s.kick == nil {
		s.kick = make(chan struct{}, 1)
	}
	s.clocks = map[int64]CameraClock{}
	kick := s.kick
	s.mu.Unlock()
	every := s.Every
	if every <= 0 {
		every = 30 * time.Minute
	}
	// Let the cameras' streams start first.
	select {
	case <-ctx.Done():
		return
	case <-time.After(20 * time.Second):
	case <-kick:
	}
	for {
		if s.Enabled == nil || s.Enabled() {
			s.checkAll(ctx)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(every):
		case <-kick:
		}
	}
}

func (s *Syncer) checkAll(ctx context.Context) {
	cams, err := s.Store.Cameras()
	if err != nil {
		return
	}
	for _, c := range cams {
		if !c.Enabled || ctx.Err() != nil {
			continue
		}
		cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		st := s.check(cctx, c)
		cancel()
		s.mu.Lock()
		s.clocks[c.ID] = st
		s.mu.Unlock()
	}
}

// localIP is this server's address as the camera sees it.
func localIP(host string) string {
	conn, err := net.Dial("udp", net.JoinHostPort(host, "123"))
	if err != nil {
		return ""
	}
	defer conn.Close()
	if a, ok := conn.LocalAddr().(*net.UDPAddr); ok && a.IP.To4() != nil {
		return a.IP.String()
	}
	return ""
}

func (s *Syncer) check(ctx context.Context, c store.Camera) CameraClock {
	st := CameraClock{CheckedAt: time.Now().UnixMilli()}
	host, port, user, pass, err := s.Target(c)
	if err != nil {
		st.Error = err.Error()
		return st
	}
	cl := onvif.New("http://"+net.JoinHostPort(host, strconv.Itoa(port))+"/onvif/device_service", user, pass)
	clk, err := cl.GetClock(ctx)
	if err != nil {
		st.Error = "could not read the camera's clock: " + err.Error()
		return st
	}
	st.OffsetMs = clk.Offset().Milliseconds()

	// Which time server the camera uses (set in the camera's own settings; the server
	// doesn't change it, since another server could be managing the same camera).
	if servers, dhcp, err := cl.NTPServers(ctx); err == nil && clk.NTP {
		if len(servers) > 0 {
			st.NTPServer = servers[0]
		}
		me := localIP(host)
		for _, sv := range servers {
			if sv == me && me != "" && !dhcp {
				st.UsesUs = true
			}
		}
	}

	// Correct a clock that is off now.
	max := s.MaxOffset
	if max <= 0 {
		max = 2 * time.Second
	}
	// Only a server whose own clock is synchronised may set cameras (an offline
	// machine must not drag them to its time).
	if off := clk.Offset(); (off > max || off < -max) && clockSynced() {
		if err := setNow(ctx, cl, clk); err != nil {
			st.Error = "could not set the camera's clock: " + err.Error()
			return st
		}
		st.Corrected = time.Now().UnixMilli()
		if again, err := cl.GetClock(ctx); err == nil {
			st.OffsetMs = again.Offset().Milliseconds()
		}
		slog.Info("corrected camera clock", "camera", c.ID, "was_off_ms", off.Milliseconds(), "now_off_ms", st.OffsetMs)
	}
	return st
}

// setNow sets the camera's clock to ours, at the start of a second (the camera
// only takes whole seconds), then returns it to NTP time if it was using that.
func setNow(ctx context.Context, cl *onvif.Client, keep onvif.Clock) error {
	now := time.Now()
	next := now.Truncate(time.Second).Add(time.Second)
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(next.Sub(now)):
	}
	if err := cl.SetClock(ctx, false, next, keep); err != nil {
		return err
	}
	if keep.NTP {
		return cl.SetClock(ctx, true, time.Time{}, keep)
	}
	return nil
}
