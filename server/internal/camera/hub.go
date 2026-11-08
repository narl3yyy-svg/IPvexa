package camera

import (
	"sync"
)

const tsPacket = 188

// Hub fans one MPEG-TS stream out to many viewers.
//
// It keeps the most recent PAT/PMT and everything since the last keyframe
// (the "GOP cache"), so a new viewer gets a decodable picture immediately
// instead of waiting for the camera's next keyframe.
type Hub struct {
	mu      sync.Mutex
	subs    map[*Sub]struct{}
	pat     []byte
	pmt     []byte
	gop     []byte
	carry   []byte
	maxGOP  int
	bytesIn uint64
}

type Sub struct {
	C    chan []byte
	once sync.Once
	hub  *Hub
}

func NewHub() *Hub {
	return &Hub{subs: map[*Sub]struct{}{}, maxGOP: 16 << 20}
}

// Subscribe registers a viewer. The returned channel first delivers the cached
// stream header and GOP, then live data. It is closed if the viewer falls too far behind.
func (h *Hub) Subscribe() *Sub {
	s := &Sub{C: make(chan []byte, 512), hub: h}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.gop) > 0 {
		head := make([]byte, 0, len(h.pat)+len(h.pmt)+len(h.gop))
		head = append(head, h.pat...)
		head = append(head, h.pmt...)
		head = append(head, h.gop...)
		s.C <- head
	}
	h.subs[s] = struct{}{}
	return s
}

func (s *Sub) Close() {
	s.hub.mu.Lock()
	delete(s.hub.subs, s)
	s.hub.mu.Unlock()
	s.once.Do(func() { close(s.C) })
}

func (h *Hub) Viewers() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs)
}

// Reset drops cached state; called when the source reconnects.
func (h *Hub) Reset() {
	h.mu.Lock()
	h.pat, h.pmt, h.gop, h.carry = nil, nil, nil, nil
	h.mu.Unlock()
}

// Write accepts arbitrary-sized chunks of TS data from the source.
func (h *Hub) Write(p []byte) (int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.bytesIn += uint64(len(p))
	data := p
	if len(h.carry) > 0 {
		data = append(h.carry, p...)
		h.carry = nil
	}
	// Resynchronise on the TS sync byte if needed.
	for len(data) > 0 && data[0] != 0x47 {
		data = data[1:]
	}
	n := len(data) / tsPacket * tsPacket
	if rem := data[n:]; len(rem) > 0 {
		h.carry = append([]byte(nil), rem...)
	}
	if n == 0 {
		return len(p), nil
	}
	chunk := make([]byte, n)
	copy(chunk, data[:n])

	for off := 0; off < n; off += tsPacket {
		pkt := chunk[off : off+tsPacket]
		pid := int(pkt[1]&0x1f)<<8 | int(pkt[2])
		switch {
		case pid == 0:
			h.pat = append(h.pat[:0], pkt...)
			continue
		case pid == 0x1000: // ffmpeg's default PMT PID
			h.pmt = append(h.pmt[:0], pkt...)
			continue
		}
		afc := (pkt[3] >> 4) & 3
		if (afc == 2 || afc == 3) && pkt[4] > 0 && pkt[5]&0x40 != 0 {
			// random_access_indicator: a keyframe starts here.
			h.gop = h.gop[:0]
		}
		if len(h.gop)+tsPacket <= h.maxGOP {
			h.gop = append(h.gop, pkt...)
		}
	}

	for s := range h.subs {
		select {
		case s.C <- chunk:
		default:
			// Viewer is too slow; drop it so it can't stall recording or other viewers.
			delete(h.subs, s)
			s.once.Do(func() { close(s.C) })
		}
	}
	return len(p), nil
}

func (h *Hub) BytesIn() uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.bytesIn
}
