package store

import (
	"database/sql"
	"encoding/json"
	"errors"
)

// Setting returns a stored value, or "" when it isn't set.
func (s *Store) Setting(key string) (string, error) {
	var v string
	err := s.db.QueryRow(`SELECT value FROM settings WHERE key = ?`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return v, err
}

func (s *Store) SetSetting(key, value string) error {
	_, err := s.db.Exec(`INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

// SettingJSON decodes a JSON setting into v; a missing setting leaves v unchanged.
func (s *Store) SettingJSON(key string, v any) error {
	raw, err := s.Setting(key)
	if err != nil || raw == "" {
		return err
	}
	return json.Unmarshal([]byte(raw), v)
}

func (s *Store) SetSettingJSON(key string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return s.SetSetting(key, string(b))
}

// ServerSettings are adjustable from the app (admins). Zero values mean "default".
type ServerSettings struct {
	MinFreePct   float64 `json:"min_free_pct"`   // keep this much of the recording disk free
	MaxStorageGB float64 `json:"max_storage_gb"` // cap on all footage; 0 = no cap
	EventDays    int     `json:"event_days"`     // keep motion events this long
	// RecordPath is where new recordings go; empty = <data>/recordings.
	RecordPath string `json:"record_path"`
	// MotionPadSec is how much footage motion-only recording keeps before and after each event.
	MotionPadSec int `json:"motion_pad_sec"`
	// RetentionDays is how long new cameras keep footage by default.
	RetentionDays int `json:"retention_days"`
}

// Server returns the server settings with defaults filled in.
func (s *Store) Server(defaultMinFree float64) ServerSettings {
	var v ServerSettings
	s.SettingJSON("server", &v)
	if v.MinFreePct <= 0 {
		v.MinFreePct = defaultMinFree
	}
	if v.EventDays <= 0 {
		v.EventDays = 90
	}
	if v.MotionPadSec <= 0 {
		v.MotionPadSec = 10
	}
	if v.RetentionDays <= 0 {
		v.RetentionDays = 30
	}
	return v
}

// TotalFootageBytes is the size of all indexed recordings.
func (s *Store) TotalFootageBytes() (int64, error) {
	var n int64
	err := s.db.QueryRow(`SELECT COALESCE(SUM(size),0) FROM segments`).Scan(&n)
	return n, err
}
