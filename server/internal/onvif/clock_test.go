package onvif

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const dahuaClock = `<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><s:Body><tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:DateTimeType>NTP</tt:DateTimeType><tt:DaylightSavings>true</tt:DaylightSavings><tt:TimeZone><tt:TZ>GMT-08:00PDT,M3.1.1/02:00:00,M11.1.2/02:00:00</tt:TZ></tt:TimeZone><tt:UTCDateTime><tt:Time><tt:Hour>1</tt:Hour><tt:Minute>3</tt:Minute><tt:Second>40</tt:Second></tt:Time><tt:Date><tt:Year>2026</tt:Year><tt:Month>11</tt:Month><tt:Day>10</tt:Day></tt:Date></tt:UTCDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse></s:Body></s:Envelope>`

func TestParseClock(t *testing.T) {
	c, err := parseClock(dahuaClock)
	if err != nil {
		t.Fatal(err)
	}
	want := time.Date(2026, 11, 10, 1, 3, 40, 0, time.UTC)
	if !c.UTC.Equal(want) || !c.NTP || !c.DST || !strings.HasPrefix(c.TZ, "GMT-08:00PDT") {
		t.Errorf("%+v", c)
	}
}

// Setting the clock sends the time in UTC, keeps the DST flag and leaves the
// camera's time zone alone; switching to NTP sends no time.
func TestSetClockBody(t *testing.T) {
	var bodies []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		bodies = append(bodies, string(b))
		io.WriteString(w, `<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body/></s:Envelope>`)
	}))
	defer srv.Close()
	c := New(srv.URL+"/onvif/device_service", "admin", "pw")
	keep := Clock{DST: true, TZ: "PST8PDT"}
	at := time.Date(2026, 11, 9, 17, 3, 41, 0, time.FixedZone("PST", -8*3600))
	if err := c.SetClock(context.Background(), false, at, keep); err != nil {
		t.Fatal(err)
	}
	if err := c.SetClock(context.Background(), true, time.Time{}, keep); err != nil {
		t.Fatal(err)
	}
	m := bodies[0]
	for _, want := range []string{"<tds:DateTimeType>Manual<", "<tds:DaylightSavings>true<", "<tt:Year>2026<", "<tt:Day>10<", "<tt:Hour>1<", "<tt:Second>41<"} {
		if !strings.Contains(m, want) {
			t.Errorf("manual set lacks %s", want)
		}
	}
	if strings.Contains(m, "TimeZone") {
		t.Error("must not change the camera's time zone")
	}
	if n := bodies[len(bodies)-1]; !strings.Contains(n, "<tds:DateTimeType>NTP<") || strings.Contains(n, "UTCDateTime") {
		t.Error("NTP switch body wrong")
	}
}

func TestNTPServersAndSet(t *testing.T) {
	var last string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		last = string(b)
		if strings.Contains(last, "GetNTP") {
			io.WriteString(w, `<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body><tds:GetNTPResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><tds:NTPInformation><tt:FromDHCP>false</tt:FromDHCP><tt:NTPManual><tt:Type>DNS</tt:Type><tt:DNSname>pool.ntp.org</tt:DNSname></tt:NTPManual></tds:NTPInformation></tds:GetNTPResponse></s:Body></s:Envelope>`)
			return
		}
		io.WriteString(w, `<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body/></s:Envelope>`)
	}))
	defer srv.Close()
	c := New(srv.URL+"/onvif/device_service", "admin", "pw")
	servers, dhcp, err := c.NTPServers(context.Background())
	if err != nil || dhcp || len(servers) != 1 || servers[0] != "pool.ntp.org" {
		t.Fatalf("%v %v %v", servers, dhcp, err)
	}
	if err := c.SetNTPServer(context.Background(), "192.168.1.2"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(last, "<tt:IPv4Address>192.168.1.2<") || !strings.Contains(last, "<tds:FromDHCP>false<") {
		t.Errorf("SetNTP body: %s", last)
	}
}
