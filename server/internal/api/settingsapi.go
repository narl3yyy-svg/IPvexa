package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"ipvexa/internal/storage"
	"ipvexa/internal/store"
)

type settingsView struct {
	store.ServerSettings
	RecordingsDir string            `json:"recordings_dir"`
	DataDir       string            `json:"data_dir"`
	Disk          storage.DiskUsage `json:"disk"`
	FootageBytes  int64             `json:"footage_bytes"`
	Version       string            `json:"version"`
}

func (s *Server) getSettings(w http.ResponseWriter, r *http.Request) {
	du, _ := storage.Usage(s.RecRoot)
	total, _ := s.Store.TotalFootageBytes()
	writeJSON(w, 200, settingsView{ServerSettings: s.Store.Server(s.MinFreePct), RecordingsDir: s.RecRoot,
		DataDir: s.DataDir, Disk: du, FootageBytes: total, Version: Version})
}

func (s *Server) putSettings(w http.ResponseWriter, r *http.Request) {
	var v store.ServerSettings
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&v); err != nil {
		writeErr(w, 400, "bad request")
		return
	}
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
	}
	if err := s.Store.SetSettingJSON("server", v); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	s.audit(r, "settings.update", fmt.Sprintf("min free %.0f%%, cap %.0f GB, events %d days", v.MinFreePct, v.MaxStorageGB, v.EventDays))
	s.getSettings(w, r)
}
