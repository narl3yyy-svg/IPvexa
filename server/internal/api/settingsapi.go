package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"strings"

	"ipvexa/internal/ai"
	"ipvexa/internal/camera"
	"ipvexa/internal/storage"
	"ipvexa/internal/store"
)

type settingsView struct {
	store.ServerSettings
	RecordingsDir string            `json:"recordings_dir"`         // where new recordings go
	DefaultDir    string            `json:"default_recordings_dir"` // the folder used when record_path is empty
	DataDir       string            `json:"data_dir"`
	Disk          storage.DiskUsage `json:"disk"`
	FootageBytes  int64             `json:"footage_bytes"`
	Version       string            `json:"version"`
	TimeServer    *timeServerView   `json:"time_server,omitempty"`
	AI            ai.Status         `json:"ai"` // the object detector
}

// timeServerView reports the server's time service for cameras.
type timeServerView struct {
	Running bool   `json:"running"`
	Error   string `json:"error,omitempty"`
	Served  int    `json:"served"` // time requests answered since the server started
	// Addresses are this server's IPv4 addresses: what to enter as the NTP server
	// in each camera's settings.
	Addresses []string `json:"addresses"`
}

func localIPv4s() []string {
	var out []string
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && !n.IP.IsLoopback() && !n.IP.IsLinkLocalUnicast() {
			out = append(out, n.IP.String())
		}
	}
	return out
}

func (s *Server) getSettings(w http.ResponseWriter, r *http.Request) {
	root := s.Cams.Root()
	du, _ := storage.Usage(root)
	total, _ := s.Store.TotalFootageBytes()
	writeJSON(w, 200, settingsView{ServerSettings: s.Store.Server(s.MinFreePct), RecordingsDir: root, DefaultDir: s.RecRoot,
		DataDir: s.DataDir, Disk: du, FootageBytes: total, Version: Version, TimeServer: s.timeServer(), AI: s.AI.Status()})
}

func (s *Server) timeServer() *timeServerView {
	if s.Clocks == nil || s.Clocks.NTP == nil {
		return nil
	}
	running, err, served := s.Clocks.NTP.Status()
	return &timeServerView{Running: running, Error: err, Served: served, Addresses: localIPv4s()}
}

func (s *Server) putSettings(w http.ResponseWriter, r *http.Request) {
	var req struct {
		store.ServerSettings
		ApplyRetention bool `json:"apply_retention_to_all"` // also set every camera's retention
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&req); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
	v := req.ServerSettings
	switch {
	case v.MinFreePct < 1 || v.MinFreePct > 50:
		writeErr(w, 400, "keep between 1% and 50% of the disk free")
		return
	case v.MaxStorageGB < 0:
		writeErr(w, 400, "the storage limit can't be negative")
		return
	case v.EventDays < 1 || v.EventDays > 3650:
		writeErr(w, 400, "keep motion events for 1 to 3650 days")
		return
	case v.MotionPadSec < 0 || v.MotionPadSec > 300:
		writeErr(w, 400, "the motion buffer must be 0 to 300 seconds")
		return
	case v.RetentionDays < 0 || v.RetentionDays > 3650:
		writeErr(w, 400, "keep recordings for 1 to 3650 days")
		return
	}
	v.RecordPath = strings.TrimSpace(v.RecordPath)
	if v.RecordPath != "" {
		v.RecordPath = filepath.Clean(v.RecordPath)
		if v.RecordPath == filepath.Clean(s.RecRoot) {
			v.RecordPath = "" // the default folder
		}
	}
	target := v.RecordPath
	if target == "" {
		target = s.RecRoot
	}
	if target != s.Cams.Root() {
		if err := camera.CheckRoot(target); err != nil {
			writeErr(w, 400, err.Error()+recordPathHint(target))
			return
		}
	}
	if err := s.Store.SetSettingJSON("server", v); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	if req.ApplyRetention && v.RetentionDays > 0 {
		if err := s.Store.SetRetentionAll(v.RetentionDays); err != nil {
			writeErr(w, 500, err.Error())
			return
		}
	}
	if target != s.Cams.Root() {
		if err := s.Cams.SetRoot(target); err != nil {
			writeErr(w, 500, err.Error())
			return
		}
	}
	if s.Clocks != nil && !v.TimeSyncOff {
		s.Clocks.Kick()
	}
	s.audit(r, "settings.update", fmt.Sprintf("min free %.0f%%, cap %.0f GB, events %d days, folder %s, motion buffer %d s, default retention %d days",
		v.MinFreePct, v.MaxStorageGB, v.EventDays, target, v.MotionPadSec, v.RetentionDays))
	s.getSettings(w, r)
}

// recordPathHint explains how to give the server access to a folder.
func recordPathHint(dir string) string {
	if !filepath.IsAbs(dir) {
		return ""
	}
	return ". The server runs as user \"ipvexa\" and may only write under /var/lib/ipvexa, /mnt, /media, /srv and /data. " +
		"To use this folder, run: sudo mkdir -p " + dir + " && sudo chown ipvexa:ipvexa " + dir
}
