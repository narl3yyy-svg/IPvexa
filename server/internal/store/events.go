package store

import (
	"strings"
	"time"
)

// Event is something that happened on a camera at a time: motion (from the
// detector) or a bookmark (added by a user, with a note).
type Event struct {
	ID       int64   `json:"id"`
	CameraID int64   `json:"camera_id"`
	Kind     string  `json:"kind"`  // "motion" | "bookmark"
	Start    int64   `json:"start"` // unix ms
	End      int64   `json:"end"`   // unix ms; 0 while a motion event is ongoing
	Cells    string  `json:"cells,omitempty"`
	Level    float64 `json:"level,omitempty"`
	Note     string  `json:"note,omitempty"`
	Author   string  `json:"author,omitempty"`
}

const eventCols = `id, camera_id, kind, start_ms, end_ms, cells, level, note, author`

func (s *Store) AddEvent(e *Event) error {
	res, err := s.db.Exec(`INSERT INTO events (camera_id, kind, start_ms, end_ms, cells, level, note, author) VALUES (?,?,?,?,?,?,?,?)`,
		e.CameraID, e.Kind, e.Start, e.End, e.Cells, e.Level, e.Note, e.Author)
	if err != nil {
		return err
	}
	e.ID, err = res.LastInsertId()
	return err
}

// FinishEvent sets the end time, cells and peak level of an event.
func (s *Store) FinishEvent(id, end int64, cells string, level float64) error {
	_, err := s.db.Exec(`UPDATE events SET end_ms=?, cells=?, level=? WHERE id=?`, end, cells, level, id)
	return err
}

func (s *Store) UpdateEventNote(id int64, note string) error {
	res, err := s.db.Exec(`UPDATE events SET note=? WHERE id=? AND kind='bookmark'`, note, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) DeleteEvent(id int64) error {
	res, err := s.db.Exec(`DELETE FROM events WHERE id=?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) EventByID(id int64) (Event, error) {
	var e Event
	err := s.db.QueryRow(`SELECT `+eventCols+` FROM events WHERE id=?`, id).
		Scan(&e.ID, &e.CameraID, &e.Kind, &e.Start, &e.End, &e.Cells, &e.Level, &e.Note, &e.Author)
	if err != nil {
		return e, ErrNotFound
	}
	return e, nil
}

// EventQuery selects events. Zero values mean "any".
type EventQuery struct {
	Cameras  []int64 // nil = all cameras
	Kind     string
	From, To int64 // overlap with [From, To)
	Limit    int
	Newest   bool // newest first (default oldest first)
}

func (s *Store) Events(q EventQuery) ([]Event, error) {
	where := []string{"1=1"}
	args := []any{}
	if q.Cameras != nil {
		if len(q.Cameras) == 0 {
			return []Event{}, nil
		}
		ph := strings.TrimSuffix(strings.Repeat("?,", len(q.Cameras)), ",")
		where = append(where, "camera_id IN ("+ph+")")
		for _, id := range q.Cameras {
			args = append(args, id)
		}
	}
	if q.Kind != "" {
		where = append(where, "kind = ?")
		args = append(args, q.Kind)
	}
	if q.To > 0 {
		where = append(where, "start_ms < ?")
		args = append(args, q.To)
	}
	if q.From > 0 {
		// Ongoing events (end 0) overlap anything after their start.
		where = append(where, "(end_ms >= ? OR end_ms = 0)")
		args = append(args, q.From)
	}
	order := "start_ms"
	if q.Newest {
		order = "start_ms DESC"
	}
	limit := q.Limit
	if limit <= 0 || limit > 5000 {
		limit = 5000
	}
	rows, err := s.db.Query(`SELECT `+eventCols+` FROM events WHERE `+strings.Join(where, " AND ")+` ORDER BY `+order+` LIMIT ?`,
		append(args, limit)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Event{}
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.ID, &e.CameraID, &e.Kind, &e.Start, &e.End, &e.Cells, &e.Level, &e.Note, &e.Author); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// CloseOpenEvents ends motion events left open by a crash or restart.
func (s *Store) CloseOpenEvents() {
	s.db.Exec(`UPDATE events SET end_ms = start_ms WHERE end_ms = 0 AND kind = 'motion'`)
}

// PurgeEvents removes motion events that started before t (bookmarks are kept).
func (s *Store) PurgeEvents(beforeMs int64) {
	s.db.Exec(`DELETE FROM events WHERE kind = 'motion' AND start_ms < ?`, beforeMs)
}

// ---- audit log ----

type AuditEntry struct {
	At       int64  `json:"at"`
	Username string `json:"username"`
	Action   string `json:"action"`
	Detail   string `json:"detail"`
}

func (s *Store) Audit(user, action, detail string) {
	s.db.Exec(`INSERT INTO audit (at_ms, username, action, detail) VALUES (?,?,?,?)`, time.Now().UnixMilli(), user, action, detail)
}

func (s *Store) AuditLog(limit int) ([]AuditEntry, error) {
	if limit <= 0 || limit > 2000 {
		limit = 500
	}
	rows, err := s.db.Query(`SELECT at_ms, username, action, detail FROM audit ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AuditEntry{}
	for rows.Next() {
		var a AuditEntry
		if err := rows.Scan(&a.At, &a.Username, &a.Action, &a.Detail); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// PurgeAudit keeps the audit log bounded.
func (s *Store) PurgeAudit(beforeMs int64) {
	s.db.Exec(`DELETE FROM audit WHERE at_ms < ?`, beforeMs)
}
