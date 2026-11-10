package onvif

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Clock is a camera's date and time settings as reported over ONVIF.
type Clock struct {
	UTC      time.Time // the camera's clock (whole seconds)
	NTP      bool      // the camera sets its clock from an NTP server
	DST      bool      // daylight saving flag
	TZ       string    // POSIX time zone, e.g. "PST8PDT,M3.2.0,M11.1.0"
	SentAt   time.Time // when we asked
	Received time.Time // when the answer came
}

// Offset is how far the camera's clock is ahead of ours (negative = behind). The
// camera only reports whole seconds, so this is accurate to about half a second.
func (c Clock) Offset() time.Duration {
	mid := c.SentAt.Add(c.Received.Sub(c.SentAt) / 2)
	return c.UTC.Add(500 * time.Millisecond).Sub(mid) // a reported second covers the next 1000 ms
}

var (
	utcBlockRe = regexp.MustCompile(`(?s)<(?:[\w.-]+:)?UTCDateTime>.*?</(?:[\w.-]+:)?UTCDateTime>`)
	dtTypeRe   = regexp.MustCompile(`<(?:[\w.-]+:)?DateTimeType>\s*(\w+)\s*<`)
	dstRe      = regexp.MustCompile(`<(?:[\w.-]+:)?DaylightSavings>\s*(\w+)\s*<`)
	tzRe       = regexp.MustCompile(`<(?:[\w.-]+:)?TZ>\s*([^<]*?)\s*<`)
	fromDHCP   = regexp.MustCompile(`<(?:[\w.-]+:)?FromDHCP>\s*(\w+)\s*<`)
	ntpAddrRe  = regexp.MustCompile(`(?s)<(?:[\w.-]+:)?NTPManual>.*?</(?:[\w.-]+:)?NTPManual>`)
	ipv4Re     = regexp.MustCompile(`<(?:[\w.-]+:)?(?:IPv4Address|DNSname)>\s*([^<\s]+)\s*<`)
)

func parseClock(s string) (Clock, error) {
	// Cameras list the date and time parts in either order: read each by name.
	blk := utcBlockRe.FindString(s)
	if blk == "" {
		return Clock{}, fmt.Errorf("camera did not report its time")
	}
	var v [6]int
	for i, name := range []string{"Year", "Month", "Day", "Hour", "Minute", "Second"} {
		m := regexp.MustCompile(`<(?:[\w.-]+:)?` + name + `>\s*(\d+)\s*<`).FindStringSubmatch(blk)
		if m == nil {
			return Clock{}, fmt.Errorf("camera did not report its time")
		}
		fmt.Sscan(m[1], &v[i])
	}
	c := Clock{UTC: time.Date(v[0], time.Month(v[1]), v[2], v[3], v[4], v[5], 0, time.UTC)}
	if m := dtTypeRe.FindStringSubmatch(s); m != nil {
		c.NTP = strings.EqualFold(m[1], "NTP")
	}
	if m := dstRe.FindStringSubmatch(s); m != nil {
		c.DST = strings.EqualFold(m[1], "true")
	}
	if m := tzRe.FindStringSubmatch(s); m != nil {
		c.TZ = m[1]
	}
	return c, nil
}

// GetClock reads the camera's clock. No login is needed for this on most cameras;
// the login is tried if the camera asks for one.
func (c *Client) GetClock(ctx context.Context) (Clock, error) {
	sent := time.Now()
	s, err := c.call(ctx, c.DeviceURL, `<tds:GetSystemDateAndTime/>`, false)
	if err == errAuth || (err != nil && c.User != "") {
		sent = time.Now()
		s, err = c.call(ctx, c.DeviceURL, `<tds:GetSystemDateAndTime/>`, true)
	}
	recv := time.Now()
	if err != nil {
		return Clock{}, err
	}
	clk, err := parseClock(s)
	if err != nil {
		return clk, err
	}
	clk.SentAt, clk.Received = sent, recv
	// Logins carry a timestamp; remember how far off the camera is in case it checks it.
	if d := clk.Offset(); d > 5*time.Second || d < -5*time.Second {
		c.skew = d
	} else {
		c.skew = 0
	}
	return clk, nil
}

// NTPServers returns the NTP servers the camera is set to use, and whether it
// takes them from DHCP instead.
func (c *Client) NTPServers(ctx context.Context) (servers []string, dhcp bool, err error) {
	s, err := c.call(ctx, c.DeviceURL, `<tds:GetNTP/>`, true)
	if err != nil {
		return nil, false, err
	}
	if m := fromDHCP.FindStringSubmatch(s); m != nil {
		dhcp = strings.EqualFold(m[1], "true")
	}
	for _, block := range ntpAddrRe.FindAllString(s, -1) {
		for _, m := range ipv4Re.FindAllStringSubmatch(block, -1) {
			servers = append(servers, m[1])
		}
	}
	return servers, dhcp, nil
}

// SetNTPServer makes the camera use one NTP server, given by IPv4 address.
func (c *Client) SetNTPServer(ctx context.Context, ip string) error {
	_, err := c.call(ctx, c.DeviceURL, `<tds:SetNTP><tds:FromDHCP>false</tds:FromDHCP>`+
		`<tds:NTPManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>`+xmlEscape(ip)+`</tt:IPv4Address></tds:NTPManual></tds:SetNTP>`, true)
	return err
}

// SetClock sets how the camera keeps time. Its time zone settings are left alone
// (only the daylight saving flag is required, and it is passed back unchanged). With ntp=false the clock is set to utc (whole seconds).
func (c *Client) SetClock(ctx context.Context, ntp bool, utc time.Time, keep Clock) error {
	body := `<tds:SetSystemDateAndTime>`
	if ntp {
		body += `<tds:DateTimeType>NTP</tds:DateTimeType>`
	} else {
		body += `<tds:DateTimeType>Manual</tds:DateTimeType>`
	}
	body += fmt.Sprintf(`<tds:DaylightSavings>%t</tds:DaylightSavings>`, keep.DST)
	// No TimeZone element: the camera keeps its own time zone and DST rules.
	if !ntp {
		u := utc.UTC()
		body += fmt.Sprintf(`<tds:UTCDateTime><tt:Date><tt:Year>%d</tt:Year><tt:Month>%d</tt:Month><tt:Day>%d</tt:Day></tt:Date>`+
			`<tt:Time><tt:Hour>%d</tt:Hour><tt:Minute>%d</tt:Minute><tt:Second>%d</tt:Second></tt:Time></tds:UTCDateTime>`,
			u.Year(), int(u.Month()), u.Day(), u.Hour(), u.Minute(), u.Second())
	}
	body += `</tds:SetSystemDateAndTime>`
	_, err := c.call(ctx, c.DeviceURL, body, true)
	return err
}
