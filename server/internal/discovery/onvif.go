// Package discovery finds ONVIF cameras on the local network with WS-Discovery.
package discovery

import (
	"context"
	"crypto/rand"
	"encoding/xml"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"
)

type Device struct {
	Address  string   `json:"address"` // IP
	XAddrs   []string `json:"xaddrs"`  // ONVIF device service URLs
	Name     string   `json:"name,omitempty"`
	Hardware string   `json:"hardware,omitempty"`
	Scopes   []string `json:"scopes,omitempty"`
}

const probeTmpl = `<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
<e:Header><w:MessageID>uuid:%s</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>
<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>`

type probeMatches struct {
	Matches []struct {
		XAddrs string `xml:"XAddrs"`
		Scopes string `xml:"Scopes"`
	} `xml:"Body>ProbeMatches>ProbeMatch"`
}

func uuid() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// Probe broadcasts a WS-Discovery probe and collects replies until ctx expires.
func Probe(ctx context.Context) ([]Device, error) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{})
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	dst := &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 3702}
	msg := []byte(fmt.Sprintf(probeTmpl, uuid()))
	for i := 0; i < 2; i++ { // UDP is lossy; send twice
		conn.WriteToUDP(msg, dst)
	}
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(3 * time.Second)
	}
	conn.SetReadDeadline(deadline)

	found := map[string]*Device{}
	buf := make([]byte, 65536)
	for {
		n, from, err := conn.ReadFromUDP(buf)
		if err != nil {
			break
		}
		var pm probeMatches
		if xml.Unmarshal(buf[:n], &pm) != nil {
			continue
		}
		for _, m := range pm.Matches {
			ip := from.IP.String()
			d := found[ip]
			if d == nil {
				d = &Device{Address: ip}
				found[ip] = d
			}
			for _, x := range strings.Fields(m.XAddrs) {
				d.XAddrs = appendUnique(d.XAddrs, x)
			}
			for _, sc := range strings.Fields(m.Scopes) {
				d.Scopes = appendUnique(d.Scopes, sc)
				if v, ok := scopeValue(sc, "name/"); ok {
					d.Name = v
				}
				if v, ok := scopeValue(sc, "hardware/"); ok {
					d.Hardware = v
				}
			}
		}
	}
	out := make([]Device, 0, len(found))
	for _, d := range found {
		out = append(out, *d)
	}
	return out, nil
}

func scopeValue(scope, key string) (string, bool) {
	i := strings.Index(scope, "onvif://www.onvif.org/"+key)
	if i < 0 {
		return "", false
	}
	v, err := url.PathUnescape(scope[i+len("onvif://www.onvif.org/")+len(key):])
	if err != nil {
		return "", false
	}
	return v, true
}

func appendUnique(s []string, v string) []string {
	for _, x := range s {
		if x == v {
			return s
		}
	}
	return append(s, v)
}
