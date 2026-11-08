package onvif

import (
	"context"
	"errors"
	"html"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// DeviceInfo is the camera's self-description (GetDeviceInformation).
type DeviceInfo struct {
	Manufacturer string `json:"manufacturer"`
	Model        string `json:"model"`
	Firmware     string `json:"firmware"`
}

// Profile is one ONVIF media profile with its video settings and RTSP address.
type Profile struct {
	Token    string `json:"token"`
	Name     string `json:"name"`
	Encoding string `json:"encoding"` // H264, H265, JPEG… as the camera reports it
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	FPS      int    `json:"fps"`
	URI      string `json:"uri"` // rtsp://… without login
}

// StreamInfo is what Probe found: the device and its profiles, with the best
// high- and low-resolution choices for the main and sub streams.
type StreamInfo struct {
	Device   DeviceInfo `json:"device"`
	Profiles []Profile  `json:"profiles"`
	Main     string     `json:"main"`
	Sub      string     `json:"sub"`
}

var (
	profileBlockRe = regexp.MustCompile(`(?s)<(?:[\w.-]+:)?Profiles\b[^>]*?\stoken="([^"]+)"[^>]*>(.*?)</(?:[\w.-]+:)?Profiles>`)
	videoEncRe     = regexp.MustCompile(`(?s)<(?:[\w.-]+:)?VideoEncoderConfiguration\b[^>]*>(.*?)</(?:[\w.-]+:)?VideoEncoderConfiguration>`)
	encodingRe     = regexp.MustCompile(`<(?:[\w.-]+:)?Encoding>\s*([^<\s]+)\s*<`)
	widthRe        = regexp.MustCompile(`<(?:[\w.-]+:)?Width>\s*(\d+)\s*<`)
	heightRe       = regexp.MustCompile(`<(?:[\w.-]+:)?Height>\s*(\d+)\s*<`)
	fpsRe          = regexp.MustCompile(`<(?:[\w.-]+:)?FrameRateLimit>\s*(\d+)\s*<`)
	uriRe          = regexp.MustCompile(`<(?:[\w.-]+:)?Uri>\s*([^<]+?)\s*<`)
	manufacturerRe = regexp.MustCompile(`<(?:[\w.-]+:)?Manufacturer>\s*([^<]*?)\s*<`)
	modelRe        = regexp.MustCompile(`<(?:[\w.-]+:)?Model>\s*([^<]*?)\s*<`)
	firmwareRe     = regexp.MustCompile(`<(?:[\w.-]+:)?FirmwareVersion>\s*([^<]*?)\s*<`)
)

func first(re *regexp.Regexp, s string) string {
	if m := re.FindStringSubmatch(s); m != nil {
		return html.UnescapeString(m[1])
	}
	return ""
}

func atoi(s string) int { n, _ := strconv.Atoi(s); return n }

// parseProfiles reads the profiles of a GetProfiles response.
func parseProfiles(s string) []Profile {
	var out []Profile
	for _, m := range profileBlockRe.FindAllStringSubmatch(s, -1) {
		body := m[2]
		p := Profile{Token: html.UnescapeString(m[1]), Name: first(nameRe, body)}
		if v := videoEncRe.FindStringSubmatch(body); v != nil {
			p.Encoding = first(encodingRe, v[1])
			p.Width = atoi(first(widthRe, v[1]))
			p.Height = atoi(first(heightRe, v[1]))
			p.FPS = atoi(first(fpsRe, v[1]))
		}
		out = append(out, p)
	}
	return out
}

func parseDeviceInfo(s string) DeviceInfo {
	return DeviceInfo{Manufacturer: first(manufacturerRe, s), Model: first(modelRe, s), Firmware: first(firmwareRe, s)}
}

// cleanStreamURI removes any login from a camera-reported RTSP address and, when the
// camera reports a host we can't use (0.0.0.0, localhost, or a different address than
// the one we reached it on, e.g. behind NAT), puts our host in its place.
func cleanStreamURI(raw, host string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme == "" {
		return ""
	}
	u.User = nil
	if host != "" && u.Hostname() != host {
		if p := u.Port(); p != "" {
			u.Host = host + ":" + p
		} else {
			u.Host = host
		}
	}
	return u.String()
}

// pickStreams chooses the highest-resolution H.264/H.265 profile as the main stream
// and the lowest-resolution one as the substream (empty when there is only one).
func pickStreams(ps []Profile) (main, sub string) {
	var video []Profile
	for _, p := range ps {
		enc := strings.ToUpper(p.Encoding)
		if p.URI != "" && (enc == "" || strings.HasPrefix(enc, "H26") || enc == "HEVC") {
			video = append(video, p)
		}
	}
	if len(video) == 0 {
		return "", ""
	}
	sort.SliceStable(video, func(i, j int) bool { return video[i].Width*video[i].Height > video[j].Width*video[j].Height })
	main = video[0].URI
	if last := video[len(video)-1]; last.URI != main {
		sub = last.URI
	}
	return main, sub
}

// Probe reads the device information, media profiles and their RTSP addresses.
func (c *Client) Probe(ctx context.Context) (StreamInfo, error) {
	var info StreamInfo
	c.mu.Lock()
	c.discover(ctx)
	med := c.med
	c.mu.Unlock()

	if s, err := c.call(ctx, c.DeviceURL, `<tds:GetDeviceInformation/>`, true); err == nil {
		info.Device = parseDeviceInfo(s)
	} else if err == errAuth || err == errNotFound {
		return info, err
	}
	s, err := c.call(ctx, med, `<trt:GetProfiles/>`, true)
	if err != nil {
		return info, err
	}
	info.Profiles = parseProfiles(s)
	if len(info.Profiles) == 0 {
		return info, errors.New("camera returned no ONVIF media profiles")
	}
	host := ""
	if u, err := url.Parse(c.DeviceURL); err == nil {
		host = u.Hostname()
	}
	for i := range info.Profiles {
		p := &info.Profiles[i]
		body := `<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup>` +
			`<trt:ProfileToken>` + xmlEscape(p.Token) + `</trt:ProfileToken></trt:GetStreamUri>`
		if s, err := c.call(ctx, med, body, true); err == nil {
			p.URI = cleanStreamURI(first(uriRe, s), host)
		}
	}
	info.Main, info.Sub = pickStreams(info.Profiles)
	if info.Main == "" {
		return info, errors.New("camera did not report any H.264/H.265 stream addresses")
	}
	return info, nil
}
