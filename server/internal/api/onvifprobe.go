package api

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"ipvexa/internal/onvif"
)

// onvifProbe asks a camera for its stream addresses over ONVIF, so the user doesn't
// have to know the RTSP paths. Body: {address, port, username, password}.
func (s *Server) onvifProbe(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Address  string `json:"address"`
		Port     int    `json:"port"`
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&req); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
	host := strings.TrimSpace(req.Address)
	// Accept "host", "host:port" or a pasted URL.
	if i := strings.Index(host, "://"); i >= 0 {
		host = host[i+3:]
	}
	if i := strings.IndexAny(host, "/?"); i >= 0 {
		host = host[:i]
	}
	if i := strings.LastIndex(host, "@"); i >= 0 {
		host = host[i+1:]
	}
	if h, p, err := net.SplitHostPort(host); err == nil {
		host = h
		if n, err := strconv.Atoi(p); err == nil && req.Port == 0 {
			req.Port = n
		}
	}
	if host == "" {
		writeErr(w, 400, "enter the camera's address first")
		return
	}
	if req.Port <= 0 || req.Port > 65535 {
		req.Port = 80
	}
	hostPort := net.JoinHostPort(host, strconv.Itoa(req.Port))
	// Fail fast, with a useful message, when nothing listens on the ONVIF port.
	conn, err := net.DialTimeout("tcp", hostPort, 4*time.Second)
	if err != nil {
		writeErr(w, 502, "can't reach "+host+" on port "+strconv.Itoa(req.Port)+
			" for ONVIF. Check the control port (PTZ tab), that ONVIF is enabled on the camera, and that a firewall isn't blocking it. You can still enter the stream addresses by hand.")
		return
	}
	conn.Close()
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	dev := "http://" + hostPort + "/onvif/device_service"
	info, err := onvif.New(dev, req.Username, req.Password).Probe(ctx)
	if err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	writeJSON(w, 200, info)
}
