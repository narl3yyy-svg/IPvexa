package onvif

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const profilesXML = `<?xml version="1.0"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="x" xmlns:tt="y"><SOAP-ENV:Body><trt:GetProfilesResponse>
<trt:Profiles fixed="true" token="MediaProfile000"><tt:Name>MainStream</tt:Name>
 <tt:VideoSourceConfiguration token="V0"><tt:Name>VideoSource</tt:Name></tt:VideoSourceConfiguration>
 <tt:VideoEncoderConfiguration token="E0"><tt:Name>enc0</tt:Name><tt:Encoding>H265</tt:Encoding>
  <tt:Resolution><tt:Width>3840</tt:Width><tt:Height>2160</tt:Height></tt:Resolution>
  <tt:RateControl><tt:FrameRateLimit>20</tt:FrameRateLimit></tt:RateControl></tt:VideoEncoderConfiguration></trt:Profiles>
<trt:Profiles fixed="true" token="MediaProfile001"><tt:Name>SubStream</tt:Name>
 <tt:VideoEncoderConfiguration token="E1"><tt:Encoding>H264</tt:Encoding>
  <tt:Resolution><tt:Width>640</tt:Width><tt:Height>480</tt:Height></tt:Resolution>
  <tt:RateControl><tt:FrameRateLimit>15</tt:FrameRateLimit></tt:RateControl></tt:VideoEncoderConfiguration></trt:Profiles>
<trt:Profiles token="Snap"><tt:Name>Snapshot</tt:Name>
 <tt:VideoEncoderConfiguration><tt:Encoding>JPEG</tt:Encoding><tt:Resolution><tt:Width>1920</tt:Width><tt:Height>1080</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration></trt:Profiles>
</trt:GetProfilesResponse></SOAP-ENV:Body></SOAP-ENV:Envelope>`

func TestParseProfiles(t *testing.T) {
	ps := parseProfiles(profilesXML)
	if len(ps) != 3 {
		t.Fatalf("got %d profiles, want 3", len(ps))
	}
	p := ps[0]
	if p.Token != "MediaProfile000" || p.Name != "MainStream" || p.Encoding != "H265" || p.Width != 3840 || p.Height != 2160 || p.FPS != 20 {
		t.Errorf("profile 0 = %+v", p)
	}
	if ps[1].Name != "SubStream" || ps[1].Width != 640 || ps[1].Encoding != "H264" {
		t.Errorf("profile 1 = %+v", ps[1])
	}
}

func TestCleanStreamURI(t *testing.T) {
	cases := []struct{ in, host, want string }{
		{"rtsp://admin:secret@192.168.1.64:554/cam/realmonitor?channel=1&subtype=0", "192.168.1.64", "rtsp://192.168.1.64:554/cam/realmonitor?channel=1&subtype=0"},
		{"rtsp://0.0.0.0:554/stream=0", "192.168.1.20", "rtsp://192.168.1.20:554/stream=0"},
		{"rtsp://10.1.1.5/ch0", "192.168.1.30", "rtsp://192.168.1.30/ch0"},
		{"not a url", "192.168.1.30", ""},
	}
	for _, c := range cases {
		if got := cleanStreamURI(c.in, c.host); got != c.want {
			t.Errorf("cleanStreamURI(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestPickStreams(t *testing.T) {
	ps := []Profile{
		{Encoding: "H264", Width: 640, Height: 360, URI: "rtsp://h/sub"},
		{Encoding: "JPEG", Width: 4000, Height: 3000, URI: "rtsp://h/jpeg"},
		{Encoding: "H265", Width: 2560, Height: 1440, URI: "rtsp://h/main"},
		{Encoding: "H264", Width: 1280, Height: 720, URI: ""},
	}
	main, sub := pickStreams(ps)
	if main != "rtsp://h/main" || sub != "rtsp://h/sub" {
		t.Errorf("pickStreams = %q, %q", main, sub)
	}
	main, sub = pickStreams(ps[2:3])
	if main != "rtsp://h/main" || sub != "" {
		t.Errorf("single profile: %q, %q", main, sub)
	}
}

// A fake camera answering the handful of ONVIF requests Probe makes.
func TestProbe(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		body := string(b)
		env := func(s string) {
			io.WriteString(w, `<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>`+s+`</s:Body></s:Envelope>`)
		}
		if !strings.Contains(body, "GetSystemDateAndTime") && !strings.Contains(body, "UsernameToken") {
			w.WriteHeader(400)
			env(`<s:Fault><s:Code><s:Subcode><s:Value>ter:NotAuthorized</s:Value></s:Subcode></s:Code></s:Fault>`)
			return
		}
		switch {
		case strings.Contains(body, "GetSystemDateAndTime"):
			env(`<tds:GetSystemDateAndTimeResponse/>`)
		case strings.Contains(body, "GetServices"):
			env(`<tds:GetServicesResponse><tds:Service><tds:Namespace>http://www.onvif.org/ver10/media/wsdl</tds:Namespace><tds:XAddr>http://` + r.Host + `/onvif/media_service</tds:XAddr></tds:Service></tds:GetServicesResponse>`)
		case strings.Contains(body, "GetDeviceInformation"):
			env(`<tds:GetDeviceInformationResponse><tds:Manufacturer>Acme</tds:Manufacturer><tds:Model>Cam 4K</tds:Model><tds:FirmwareVersion>1.2.3</tds:FirmwareVersion></tds:GetDeviceInformationResponse>`)
		case strings.Contains(body, "GetProfiles"):
			io.WriteString(w, profilesXML)
		case strings.Contains(body, "MediaProfile000"):
			env(`<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://user:pw@10.9.9.9:554/main?a=1&amp;b=2</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>`)
		case strings.Contains(body, "MediaProfile001"):
			env(`<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://10.9.9.9:554/sub</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>`)
		default:
			w.WriteHeader(400)
			env(`<s:Fault><s:Reason><s:Text>not supported</s:Text></s:Reason></s:Fault>`)
		}
	}))
	defer srv.Close()

	c := New(srv.URL+"/onvif/device_service", "admin", "pw")
	info, err := c.Probe(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if info.Device.Manufacturer != "Acme" || info.Device.Model != "Cam 4K" {
		t.Errorf("device = %+v", info.Device)
	}
	if info.Main != "rtsp://127.0.0.1:554/main?a=1&b=2" || info.Sub != "rtsp://127.0.0.1:554/sub" {
		t.Errorf("main/sub = %q / %q", info.Main, info.Sub)
	}
	if len(info.Profiles) != 3 || info.Profiles[2].URI != "" {
		t.Errorf("profiles = %+v", info.Profiles)
	}
}
