// Package onvif implements the small part of ONVIF that Ipvexa needs for PTZ:
// service discovery, media profiles, continuous move, stop and presets.
package onvif

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

var ErrNoPTZ = errors.New("this camera's ONVIF service does not offer PTZ (enable PTZ in the camera's ONVIF settings)")

const (
	nsPTZ   = "http://www.onvif.org/ver20/ptz/wsdl"
	nsMedia = "http://www.onvif.org/ver10/media/wsdl"
)

type Preset struct {
	Token string `json:"token"`
	Name  string `json:"name"`
}

// Client talks to one camera. It is safe for concurrent use.
type Client struct {
	DeviceURL  string // e.g. http://192.168.1.64:80/onvif/device_service
	User, Pass string

	http *http.Client
	mu   sync.Mutex
	init bool
	skew time.Duration // camera clock minus our clock, for WS-Security timestamps
	ptz  string
	med  string
	prof string
}

func New(deviceURL, user, pass string) *Client {
	return &Client{DeviceURL: deviceURL, User: user, Pass: pass, http: &http.Client{Timeout: 6 * time.Second}}
}

func xmlEscape(s string) string {
	var b bytes.Buffer
	xml.EscapeText(&b, []byte(s))
	return b.String()
}

func (c *Client) securityHeader() string {
	if c.User == "" {
		return ""
	}
	nonce := make([]byte, 16)
	rand.Read(nonce)
	created := time.Now().Add(c.skew).UTC().Format("2006-01-02T15:04:05.000Z")
	h := sha1.New()
	h.Write(nonce)
	h.Write([]byte(created))
	h.Write([]byte(c.Pass))
	digest := base64.StdEncoding.EncodeToString(h.Sum(nil))
	return `<s:Header><wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">` +
		`<wsse:UsernameToken><wsse:Username>` + xmlEscape(c.User) + `</wsse:Username>` +
		`<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">` + digest + `</wsse:Password>` +
		`<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">` + base64.StdEncoding.EncodeToString(nonce) + `</wsse:Nonce>` +
		`<wsu:Created>` + created + `</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header>`
}

var faultTextRe = regexp.MustCompile(`(?s)<(?:\w+:)?Text[^>]*>(.*?)</(?:\w+:)?Text>`)
var faultCodeRe = regexp.MustCompile(`(?s)<(?:\w+:)?Subcode>\s*<(?:\w+:)?Value>(.*?)</`)

func (c *Client) call(ctx context.Context, url, body string, auth bool) (string, error) {
	env := `<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"` +
		` xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl"` +
		` xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">`
	if auth {
		env += c.securityHeader()
	}
	env += `<s:Body>` + body + `</s:Body></s:Envelope>`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(env))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/soap+xml; charset=utf-8")
	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("camera did not answer ONVIF request: %w", err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	s := string(data)
	if resp.StatusCode != 200 || strings.Contains(s, ":Fault>") {
		msg := ""
		if m := faultTextRe.FindStringSubmatch(s); m != nil {
			msg = strings.TrimSpace(m[1])
		}
		if m := faultCodeRe.FindStringSubmatch(s); m != nil && strings.Contains(m[1], "NotAuthorized") {
			msg = "camera rejected the ONVIF login (check the ONVIF username/password)"
		}
		if resp.StatusCode == 401 {
			msg = "camera rejected the ONVIF login (check the ONVIF username/password)"
		}
		if msg == "" {
			msg = fmt.Sprintf("ONVIF error (HTTP %d)", resp.StatusCode)
		}
		return s, errors.New(msg)
	}
	return s, nil
}

var (
	svcRe     = regexp.MustCompile(`(?s)<(?:\w+:)?Namespace>\s*([^<\s]+)\s*</(?:\w+:)?Namespace>\s*<(?:\w+:)?XAddr>\s*([^<\s]+)\s*<`)
	capPTZRe  = regexp.MustCompile(`(?s)<(?:\w+:)?PTZ>\s*<(?:\w+:)?XAddr>\s*([^<\s]+)\s*<`)
	capMedRe  = regexp.MustCompile(`(?s)<(?:\w+:)?Media>\s*<(?:\w+:)?XAddr>\s*([^<\s]+)\s*<`)
	profileRe = regexp.MustCompile(`<(?:\w+:)?Profiles[^>]*\stoken="([^"]+)"`)
	presetRe  = regexp.MustCompile(`(?s)<(?:\w+:)?Preset[^>]*\stoken="([^"]*)"[^>]*>(.*?)</(?:\w+:)?Preset>`)
	nameRe    = regexp.MustCompile(`<(?:\w+:)?Name>([^<]*)<`)
	utcRe     = regexp.MustCompile(`(?s)<(?:\w+:)?UTCDateTime>.*?<(?:\w+:)?Year>(\d+)<.*?<(?:\w+:)?Month>(\d+)<.*?<(?:\w+:)?Day>(\d+)<.*?<(?:\w+:)?Hour>(\d+)<.*?<(?:\w+:)?Minute>(\d+)<.*?<(?:\w+:)?Second>(\d+)<`)
	tokenRe   = regexp.MustCompile(`<(?:\w+:)?PresetToken>([^<]+)<`)
)

// setup finds the PTZ and media services and the first media profile. Caller holds c.mu.
func (c *Client) setup(ctx context.Context) error {
	if c.init {
		return nil
	}
	// Match the camera's clock so WS-Security timestamps are accepted.
	if s, err := c.call(ctx, c.DeviceURL, `<tds:GetSystemDateAndTime/>`, false); err == nil {
		if m := utcRe.FindStringSubmatch(s); m != nil {
			var y, mo, d, h, mi, se int
			fmt.Sscan(m[1], &y)
			fmt.Sscan(m[2], &mo)
			fmt.Sscan(m[3], &d)
			fmt.Sscan(m[4], &h)
			fmt.Sscan(m[5], &mi)
			fmt.Sscan(m[6], &se)
			cam := time.Date(y, time.Month(mo), d, h, mi, se, 0, time.UTC)
			if diff := cam.Sub(time.Now()); diff > 5*time.Second || diff < -5*time.Second {
				c.skew = diff
			}
		}
	}

	if s, err := c.call(ctx, c.DeviceURL, `<tds:GetServices><tds:IncludeCapability>false</tds:IncludeCapability></tds:GetServices>`, true); err == nil {
		for _, m := range svcRe.FindAllStringSubmatch(s, -1) {
			switch m[1] {
			case nsPTZ:
				c.ptz = m[2]
			case nsMedia:
				c.med = m[2]
			}
		}
	}
	if c.ptz == "" || c.med == "" {
		s, err := c.call(ctx, c.DeviceURL, `<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>`, true)
		if err != nil && c.med == "" {
			return err
		}
		if m := capPTZRe.FindStringSubmatch(s); m != nil && c.ptz == "" {
			c.ptz = m[1]
		}
		if m := capMedRe.FindStringSubmatch(s); m != nil && c.med == "" {
			c.med = m[1]
		}
	}
	if c.ptz == "" {
		return ErrNoPTZ
	}
	if c.med == "" {
		return errors.New("camera has no ONVIF media service")
	}
	s, err := c.call(ctx, c.med, `<trt:GetProfiles/>`, true)
	if err != nil {
		return err
	}
	m := profileRe.FindStringSubmatch(s)
	if m == nil {
		return errors.New("camera returned no ONVIF media profiles")
	}
	c.prof = m[1]
	c.init = true
	return nil
}

func (c *Client) ptzCall(ctx context.Context, body string) (string, error) {
	c.mu.Lock()
	err := c.setup(ctx)
	ptz, prof := c.ptz, c.prof
	c.mu.Unlock()
	if err != nil {
		return "", err
	}
	return c.call(ctx, ptz, strings.ReplaceAll(body, "{P}", xmlEscape(prof)), true)
}

// Check verifies that PTZ is reachable and returns the presets.
func (c *Client) Check(ctx context.Context) ([]Preset, error) { return c.Presets(ctx) }

func clamp(v float64) float64 { return max(-1, min(1, v)) }

// ContinuousMove starts moving at the given normalised speeds (-1..1).
func (c *Client) ContinuousMove(ctx context.Context, pan, tilt, zoom float64) error {
	_, err := c.ptzCall(ctx, fmt.Sprintf(`<tptz:ContinuousMove><tptz:ProfileToken>{P}</tptz:ProfileToken><tptz:Velocity>`+
		`<tt:PanTilt x="%.2f" y="%.2f"/><tt:Zoom x="%.2f"/></tptz:Velocity></tptz:ContinuousMove>`, clamp(pan), clamp(tilt), clamp(zoom)))
	return err
}

func (c *Client) Stop(ctx context.Context) error {
	_, err := c.ptzCall(ctx, `<tptz:Stop><tptz:ProfileToken>{P}</tptz:ProfileToken><tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>`)
	return err
}

func (c *Client) Presets(ctx context.Context) ([]Preset, error) {
	s, err := c.ptzCall(ctx, `<tptz:GetPresets><tptz:ProfileToken>{P}</tptz:ProfileToken></tptz:GetPresets>`)
	if err != nil {
		return nil, err
	}
	out := []Preset{}
	for _, m := range presetRe.FindAllStringSubmatch(s, -1) {
		p := Preset{Token: m[1], Name: m[1]}
		if n := nameRe.FindStringSubmatch(m[2]); n != nil && strings.TrimSpace(n[1]) != "" {
			p.Name = strings.TrimSpace(n[1])
		}
		out = append(out, p)
	}
	return out, nil
}

func (c *Client) GotoPreset(ctx context.Context, token string) error {
	_, err := c.ptzCall(ctx, `<tptz:GotoPreset><tptz:ProfileToken>{P}</tptz:ProfileToken><tptz:PresetToken>`+xmlEscape(token)+`</tptz:PresetToken></tptz:GotoPreset>`)
	return err
}

// SetPreset saves the current position under name and returns the new preset token.
func (c *Client) SetPreset(ctx context.Context, name string) (string, error) {
	s, err := c.ptzCall(ctx, `<tptz:SetPreset><tptz:ProfileToken>{P}</tptz:ProfileToken><tptz:PresetName>`+xmlEscape(name)+`</tptz:PresetName></tptz:SetPreset>`)
	if err != nil {
		return "", err
	}
	if m := tokenRe.FindStringSubmatch(s); m != nil {
		return m[1], nil
	}
	return "", nil
}
