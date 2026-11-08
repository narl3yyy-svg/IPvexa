// Package ptzd drives pan/tilt cameras running OpenIPC's ptzd daemon through
// the camera web UI's JSON endpoint (/cgi-bin/j/ptzd.cgi), the same one its Live page uses.
package ptzd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

var ErrNoZoom = errors.New("this camera has pan/tilt only (no zoom)")

type Preset struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

type Status struct {
	Pan     int      `json:"pan"`
	Tilt    int      `json:"tilt"`
	PanMax  int      `json:"pan_max"`
	TiltMax int      `json:"tilt_max"`
	Moving  bool     `json:"moving"`
	Homing  bool     `json:"homing"`
	Homed   bool     `json:"homed"`
	Speed   int      `json:"speed"`
	Presets []Preset `json:"presets"`
	Error   string   `json:"error"`
}

type Client struct {
	Base       string // http://host:port
	User, Pass string
	http       *http.Client

	mu       sync.Mutex
	lastP    int
	lastT    int
	lastSent time.Time
}

func New(base, user, pass string) *Client {
	return &Client{Base: base, User: user, Pass: pass, http: &http.Client{Timeout: 6 * time.Second}}
}

func (c *Client) call(ctx context.Context, cmd string, params url.Values) (Status, error) {
	var st Status
	q := url.Values{"cmd": {cmd}}
	for k, v := range params {
		q[k] = v
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.Base+"/cgi-bin/j/ptzd.cgi?"+q.Encode(), strings.NewReader("{}"))
	if err != nil {
		return st, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.User != "" {
		req.SetBasicAuth(c.User, c.Pass)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return st, fmt.Errorf("camera did not answer: %w", err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return st, errors.New("camera rejected the login (check the camera's web username/password)")
	}
	if resp.StatusCode == 404 {
		return st, errors.New("camera has no ptzd PTZ service")
	}
	jerr := json.Unmarshal(data, &st)
	if resp.StatusCode >= 300 || st.Error != "" {
		msg := st.Error
		if msg == "" {
			msg = fmt.Sprintf("PTZ request failed (HTTP %d)", resp.StatusCode)
		}
		return st, errors.New(msg)
	}
	if jerr != nil {
		return st, errors.New("camera gave an unexpected PTZ answer")
	}
	return st, nil
}

// Probe reports whether the camera runs ptzd (status answers with a position).
func (c *Client) Probe(ctx context.Context) (Status, error) {
	st, err := c.call(ctx, "status", nil)
	if err != nil {
		return st, err
	}
	if st.PanMax == 0 && st.TiltMax == 0 {
		return st, errors.New("camera has no ptzd PTZ service")
	}
	return st, nil
}

func sign(v float64) int {
	switch {
	case v > 0.05:
		return 1
	case v < -0.05:
		return -1
	}
	return 0
}

// Move starts moving in the direction of pan/tilt (ptzd uses its own configured speed).
// Repeated calls in the same direction are not re-sent, so holding a button stays smooth.
func (c *Client) Move(ctx context.Context, pan, tilt, zoom float64) error {
	p, t := sign(pan), sign(tilt)
	if p == 0 && t == 0 {
		if sign(zoom) != 0 {
			return ErrNoZoom
		}
		return nil
	}
	c.mu.Lock()
	same := p == c.lastP && t == c.lastT && time.Since(c.lastSent) < 5*time.Second
	c.mu.Unlock()
	if same {
		return nil
	}
	if _, err := c.call(ctx, "start", url.Values{"pan": {strconv.Itoa(p)}, "tilt": {strconv.Itoa(t)}}); err != nil {
		return err
	}
	c.mu.Lock()
	c.lastP, c.lastT, c.lastSent = p, t, time.Now()
	c.mu.Unlock()
	return nil
}

func (c *Client) Stop(ctx context.Context) error {
	c.mu.Lock()
	c.lastP, c.lastT = 0, 0
	c.mu.Unlock()
	_, err := c.call(ctx, "stop", nil)
	return err
}

func (c *Client) Presets(ctx context.Context) ([]Preset, error) {
	st, err := c.call(ctx, "status", nil)
	if err != nil {
		return nil, err
	}
	if st.Presets == nil {
		return []Preset{}, nil
	}
	return st.Presets, nil
}

func (c *Client) GotoPreset(ctx context.Context, id string) error {
	_, err := c.call(ctx, "preset", url.Values{"op": {"goto"}, "id": {id}})
	return err
}

// SavePreset stores the current position as a new preset and returns its id.
func (c *Client) SavePreset(ctx context.Context, name string) (string, error) {
	st, err := c.call(ctx, "status", nil)
	if err != nil {
		return "", err
	}
	id := 1
	for _, p := range st.Presets {
		if p.ID >= id {
			id = p.ID + 1
		}
	}
	if _, err := c.call(ctx, "preset", url.Values{"op": {"save"}, "id": {strconv.Itoa(id)}, "name": {name}}); err != nil {
		return "", err
	}
	return strconv.Itoa(id), nil
}

// Action runs one of ptzd's extra commands: "center" or "home" (recalibrate).
func (c *Client) Action(ctx context.Context, name string) error {
	if name != "center" && name != "home" {
		return errors.New("unknown PTZ action")
	}
	_, err := c.call(ctx, name, nil)
	return err
}
