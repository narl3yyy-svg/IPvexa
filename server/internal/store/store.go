// Package store holds IPvexa's persistent state in a single SQLite database
// (WAL mode, so it survives power loss and lets readers and the writer run together).
package store

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

type Camera struct {
	ID            int64  `json:"id"`
	Name          string `json:"name"`
	Brand         string `json:"brand"`
	MainURL       string `json:"main_url"`
	SubURL        string `json:"sub_url"`
	Transport     string `json:"transport"`   // "tcp" (default) or "udp"
	RecordMode    string `json:"record_mode"` // "continuous", "motion" or "off"
	RecordSub     bool   `json:"record_sub"`
	RetentionDays int    `json:"retention_days"`
	Enabled       bool   `json:"enabled"`
	CreatedAt     int64  `json:"created_at"`

	// PTZ over ONVIF. OnvifUser/OnvifPass are optional; when empty the
	// credentials in MainURL are used. OnvifPass is never sent to clients.
	PTZ       bool   `json:"ptz"`
	OnvifPort int    `json:"onvif_port"`
	OnvifUser string `json:"onvif_user"`
	OnvifPass string `json:"onvif_pass,omitempty"`
	// PTZProtocol: "auto" (detect), "onvif", or "ptzd" (OpenIPC's ptzd web API).
	PTZProtocol string `json:"ptz_protocol"`

	// Motion detection (on the substream when there is one).
	Motion            bool   `json:"motion"`
	MotionSensitivity int    `json:"motion_sensitivity"` // 1…100
	MotionMask        string `json:"motion_mask"`        // hex cell set to ignore (see package motion)

	// RecordSchedule overrides RecordMode during weekly time windows.
	RecordSchedule []ScheduleRule `json:"record_schedule"`
}

type Segment struct {
	ID       int64  `json:"id"`
	CameraID int64  `json:"camera_id"`
	Stream   string `json:"stream"` // "main" or "sub"
	Path     string `json:"-"`      // absolute, or relative to the original recordings root
	Start    int64  `json:"start"`  // unix ms
	End      int64  `json:"end"`    // unix ms
	Size     int64  `json:"size"`
}

// File is the segment's file on disk. Segments recorded before the recordings
// folder was moved are stored relative to the original root.
func (g Segment) File(originalRoot string) string {
	if filepath.IsAbs(g.Path) {
		return g.Path
	}
	return filepath.Join(originalRoot, g.Path)
}

type User struct {
	ID        int64       `json:"id"`
	Username  string      `json:"username"`
	FullName  string      `json:"full_name"`
	Hash      string      `json:"-"`
	Role      string      `json:"role"` // admin | operator | viewer
	Perms     Permissions `json:"permissions"`
	Disabled  bool        `json:"disabled"`
	CreatedAt int64       `json:"created_at"`
	LastLogin int64       `json:"last_login"`
}

// Permissions limit what a non-admin user can see and do. Admins can do everything.
type Permissions struct {
	AllCameras bool    `json:"all_cameras"`
	Cameras    []int64 `json:"cameras"`  // cameras the user may see when AllCameras is false
	Playback   bool    `json:"playback"` // view recorded footage
	PTZ        bool    `json:"ptz"`      // move PTZ cameras
	Export     bool    `json:"export"`   // download video clips
}

// DefaultPermissions are what a new user of the role gets unless told otherwise.
func DefaultPermissions(role string) Permissions {
	switch role {
	case "admin", "operator":
		return Permissions{AllCameras: true, Cameras: []int64{}, Playback: true, PTZ: true, Export: true}
	default:
		return Permissions{AllCameras: true, Cameras: []int64{}, Playback: true}
	}
}

// Effective returns the user's permissions, with everything allowed for admins.
func (u User) Effective() Permissions {
	if u.Role == "admin" {
		return Permissions{AllCameras: true, Cameras: []int64{}, Playback: true, PTZ: true, Export: true}
	}
	p := u.Perms
	if p.Cameras == nil {
		p.Cameras = []int64{}
	}
	return p
}

// CanSee reports whether the user may view the camera.
func (p Permissions) CanSee(camID int64) bool {
	if p.AllCameras {
		return true
	}
	for _, id := range p.Cameras {
		if id == camID {
			return true
		}
	}
	return false
}

type Store struct{ db *sql.DB }

var ErrNotFound = errors.New("not found")

var migrations = []string{
	`CREATE TABLE cameras (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		name TEXT NOT NULL,
		brand TEXT NOT NULL DEFAULT 'generic',
		main_url TEXT NOT NULL,
		sub_url TEXT NOT NULL DEFAULT '',
		transport TEXT NOT NULL DEFAULT 'tcp',
		record_mode TEXT NOT NULL DEFAULT 'continuous',
		record_sub INTEGER NOT NULL DEFAULT 0,
		retention_days INTEGER NOT NULL DEFAULT 30,
		enabled INTEGER NOT NULL DEFAULT 1,
		created_at INTEGER NOT NULL
	);
	CREATE TABLE segments (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		camera_id INTEGER NOT NULL,
		stream TEXT NOT NULL,
		path TEXT NOT NULL UNIQUE,
		start_ms INTEGER NOT NULL,
		end_ms INTEGER NOT NULL,
		size INTEGER NOT NULL
	);
	CREATE INDEX segments_cam_time ON segments(camera_id, stream, start_ms);
	CREATE INDEX segments_start ON segments(start_ms);
	CREATE TABLE users (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		username TEXT NOT NULL UNIQUE,
		hash TEXT NOT NULL,
		role TEXT NOT NULL DEFAULT 'viewer'
	);
	CREATE TABLE sessions (
		token TEXT PRIMARY KEY,
		user_id INTEGER NOT NULL,
		expires INTEGER NOT NULL
	);
	CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);`,
	`ALTER TABLE cameras ADD COLUMN ptz INTEGER NOT NULL DEFAULT 0;
	ALTER TABLE cameras ADD COLUMN onvif_port INTEGER NOT NULL DEFAULT 80;
	ALTER TABLE cameras ADD COLUMN onvif_user TEXT NOT NULL DEFAULT '';
	ALTER TABLE cameras ADD COLUMN onvif_pass TEXT NOT NULL DEFAULT '';`,
	`ALTER TABLE cameras ADD COLUMN ptz_protocol TEXT NOT NULL DEFAULT 'auto';`,
	`ALTER TABLE users ADD COLUMN full_name TEXT NOT NULL DEFAULT '';
	ALTER TABLE users ADD COLUMN perms TEXT NOT NULL DEFAULT '';
	ALTER TABLE users ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0;
	ALTER TABLE users ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0;
	ALTER TABLE users ADD COLUMN last_login INTEGER NOT NULL DEFAULT 0;`,
	`ALTER TABLE cameras ADD COLUMN motion INTEGER NOT NULL DEFAULT 0;
	ALTER TABLE cameras ADD COLUMN motion_sensitivity INTEGER NOT NULL DEFAULT 50;
	ALTER TABLE cameras ADD COLUMN motion_mask TEXT NOT NULL DEFAULT '';
	CREATE TABLE events (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		camera_id INTEGER NOT NULL,
		kind TEXT NOT NULL,
		start_ms INTEGER NOT NULL,
		end_ms INTEGER NOT NULL DEFAULT 0,
		cells TEXT NOT NULL DEFAULT '',
		level REAL NOT NULL DEFAULT 0,
		note TEXT NOT NULL DEFAULT '',
		author TEXT NOT NULL DEFAULT ''
	);
	CREATE INDEX events_cam_time ON events(camera_id, start_ms);
	CREATE INDEX events_time ON events(start_ms);
	CREATE TABLE audit (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		at_ms INTEGER NOT NULL,
		username TEXT NOT NULL,
		action TEXT NOT NULL,
		detail TEXT NOT NULL DEFAULT ''
	);
	CREATE INDEX audit_time ON audit(at_ms);`,
	`ALTER TABLE cameras ADD COLUMN record_schedule TEXT NOT NULL DEFAULT '';`,
}

func scheduleJSON(rules []ScheduleRule) string {
	if len(rules) == 0 {
		return ""
	}
	b, _ := json.Marshal(rules)
	return string(b)
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(ON)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	var v int
	if err := s.db.QueryRow(`PRAGMA user_version`).Scan(&v); err != nil {
		return err
	}
	for i := v; i < len(migrations); i++ {
		tx, err := s.db.Begin()
		if err != nil {
			return err
		}
		if _, err := tx.Exec(migrations[i]); err != nil {
			tx.Rollback()
			return err
		}
		if _, err := tx.Exec(fmt.Sprintf(`PRAGMA user_version = %d`, i+1)); err != nil {
			tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

// ---- cameras ----

const camCols = `id, name, brand, main_url, sub_url, transport, record_mode, record_sub, retention_days, enabled, created_at, ptz, onvif_port, onvif_user, onvif_pass, ptz_protocol, motion, motion_sensitivity, motion_mask, record_schedule`

func scanCamera(r interface{ Scan(...any) error }) (Camera, error) {
	var c Camera
	var sched string
	err := r.Scan(&c.ID, &c.Name, &c.Brand, &c.MainURL, &c.SubURL, &c.Transport, &c.RecordMode, &c.RecordSub, &c.RetentionDays, &c.Enabled, &c.CreatedAt, &c.PTZ, &c.OnvifPort, &c.OnvifUser, &c.OnvifPass, &c.PTZProtocol, &c.Motion, &c.MotionSensitivity, &c.MotionMask, &sched)
	if err == nil {
		c.RecordSchedule = []ScheduleRule{}
		if sched != "" {
			json.Unmarshal([]byte(sched), &c.RecordSchedule)
		}
	}
	return c, err
}

func (s *Store) Cameras() ([]Camera, error) {
	rows, err := s.db.Query(`SELECT ` + camCols + ` FROM cameras ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Camera{}
	for rows.Next() {
		c, err := scanCamera(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// SetRetentionAll sets how long every camera keeps footage.
func (s *Store) SetRetentionAll(days int) error {
	_, err := s.db.Exec(`UPDATE cameras SET retention_days=?`, days)
	return err
}

func (s *Store) Camera(id int64) (Camera, error) {
	c, err := scanCamera(s.db.QueryRow(`SELECT `+camCols+` FROM cameras WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

func (s *Store) CreateCamera(c *Camera) error {
	c.CreatedAt = time.Now().UnixMilli()
	res, err := s.db.Exec(`INSERT INTO cameras (name, brand, main_url, sub_url, transport, record_mode, record_sub, retention_days, enabled, created_at, ptz, onvif_port, onvif_user, onvif_pass, ptz_protocol, motion, motion_sensitivity, motion_mask, record_schedule)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, c.Name, c.Brand, c.MainURL, c.SubURL, c.Transport, c.RecordMode, c.RecordSub, c.RetentionDays, c.Enabled, c.CreatedAt,
		c.PTZ, c.OnvifPort, c.OnvifUser, c.OnvifPass, c.PTZProtocol, c.Motion, c.MotionSensitivity, c.MotionMask, scheduleJSON(c.RecordSchedule))
	if err != nil {
		return err
	}
	c.ID, err = res.LastInsertId()
	return err
}

func (s *Store) UpdateCamera(c *Camera) error {
	res, err := s.db.Exec(`UPDATE cameras SET name=?, brand=?, main_url=?, sub_url=?, transport=?, record_mode=?, record_sub=?, retention_days=?, enabled=?,
		ptz=?, onvif_port=?, onvif_user=?, onvif_pass=?, ptz_protocol=?, motion=?, motion_sensitivity=?, motion_mask=?, record_schedule=? WHERE id=?`,
		c.Name, c.Brand, c.MainURL, c.SubURL, c.Transport, c.RecordMode, c.RecordSub, c.RetentionDays, c.Enabled,
		c.PTZ, c.OnvifPort, c.OnvifUser, c.OnvifPass, c.PTZProtocol, c.Motion, c.MotionSensitivity, c.MotionMask, scheduleJSON(c.RecordSchedule), c.ID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteCamera removes the camera row. Recordings are kept on disk and in the index
// until retention removes them, so deleting a camera by mistake does not destroy footage.
func (s *Store) DeleteCamera(id int64) error {
	_, err := s.db.Exec(`DELETE FROM cameras WHERE id = ?`, id)
	return err
}

// ---- segments ----

func (s *Store) AddSegment(seg *Segment) error {
	res, err := s.db.Exec(`INSERT OR IGNORE INTO segments (camera_id, stream, path, start_ms, end_ms, size) VALUES (?,?,?,?,?,?)`,
		seg.CameraID, seg.Stream, seg.Path, seg.Start, seg.End, seg.Size)
	if err != nil {
		return err
	}
	seg.ID, _ = res.LastInsertId()
	return nil
}

// Segments returns segments of one camera stream overlapping [from, to), oldest first.
func (s *Store) Segments(camID int64, stream string, from, to int64) ([]Segment, error) {
	rows, err := s.db.Query(`SELECT id, camera_id, stream, path, start_ms, end_ms, size FROM segments
		WHERE camera_id = ? AND stream = ? AND end_ms > ? AND start_ms < ? ORDER BY start_ms`, camID, stream, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Segment{}
	for rows.Next() {
		var g Segment
		if err := rows.Scan(&g.ID, &g.CameraID, &g.Stream, &g.Path, &g.Start, &g.End, &g.Size); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// OldestSegments returns the n oldest segments, optionally limited to one camera and
// to segments that ended before `before` (0 = no limit).
func (s *Store) OldestSegments(camID int64, before int64, n int) ([]Segment, error) {
	q := `SELECT id, camera_id, stream, path, start_ms, end_ms, size FROM segments WHERE 1=1`
	args := []any{}
	if camID > 0 {
		q += ` AND camera_id = ?`
		args = append(args, camID)
	}
	if before > 0 {
		q += ` AND end_ms < ?`
		args = append(args, before)
	}
	q += ` ORDER BY start_ms LIMIT ?`
	args = append(args, n)
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Segment{}
	for rows.Next() {
		var g Segment
		if err := rows.Scan(&g.ID, &g.CameraID, &g.Stream, &g.Path, &g.Start, &g.End, &g.Size); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// BytesWrittenSince sums the size of footage that started after the given time (unix ms).
func (s *Store) BytesWrittenSince(ms int64) (int64, error) {
	var n int64
	err := s.db.QueryRow(`SELECT COALESCE(SUM(size),0) FROM segments WHERE start_ms > ?`, ms).Scan(&n)
	return n, err
}

func (s *Store) DeleteSegment(id int64) error {
	_, err := s.db.Exec(`DELETE FROM segments WHERE id = ?`, id)
	return err
}

// RecordingStats summarises the indexed footage of one camera.
func (s *Store) RecordingStats(camID int64) (count int64, bytes int64, oldest int64, err error) {
	err = s.db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(size),0), COALESCE(MIN(start_ms),0) FROM segments WHERE camera_id = ?`, camID).
		Scan(&count, &bytes, &oldest)
	return
}

// ---- users & sessions ----

const userCols = `id, username, full_name, hash, role, perms, disabled, created_at, last_login`

func scanUser(r interface{ Scan(...any) error }) (User, error) {
	var u User
	var perms string
	err := r.Scan(&u.ID, &u.Username, &u.FullName, &u.Hash, &u.Role, &perms, &u.Disabled, &u.CreatedAt, &u.LastLogin)
	if errors.Is(err, sql.ErrNoRows) {
		return u, ErrNotFound
	}
	if err != nil {
		return u, err
	}
	if perms == "" || json.Unmarshal([]byte(perms), &u.Perms) != nil {
		u.Perms = DefaultPermissions(u.Role)
	}
	if u.Perms.Cameras == nil {
		u.Perms.Cameras = []int64{}
	}
	return u, nil
}

func permsJSON(p Permissions) string {
	if p.Cameras == nil {
		p.Cameras = []int64{}
	}
	b, _ := json.Marshal(p)
	return string(b)
}

func (s *Store) UserCount() (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n)
	return n, err
}

// ActiveAdminCount counts enabled admin accounts (there must always be at least one).
func (s *Store) ActiveAdminCount() (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM users WHERE role = 'admin' AND disabled = 0`).Scan(&n)
	return n, err
}

func (s *Store) Users() ([]User, error) {
	rows, err := s.db.Query(`SELECT ` + userCols + ` FROM users ORDER BY username COLLATE NOCASE`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []User{}
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (s *Store) CreateUser(u *User) error {
	if u.CreatedAt == 0 {
		u.CreatedAt = time.Now().UnixMilli()
	}
	res, err := s.db.Exec(`INSERT INTO users (username, full_name, hash, role, perms, disabled, created_at) VALUES (?,?,?,?,?,?,?)`,
		u.Username, u.FullName, u.Hash, u.Role, permsJSON(u.Perms), u.Disabled, u.CreatedAt)
	if err != nil {
		return err
	}
	u.ID, err = res.LastInsertId()
	return err
}

// UpdateUser saves everything except the password hash (see SetUserHash).
func (s *Store) UpdateUser(u User) error {
	res, err := s.db.Exec(`UPDATE users SET username=?, full_name=?, role=?, perms=?, disabled=? WHERE id=?`,
		u.Username, u.FullName, u.Role, permsJSON(u.Perms), u.Disabled, u.ID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) DeleteUser(id int64) error {
	if _, err := s.db.Exec(`DELETE FROM sessions WHERE user_id = ?`, id); err != nil {
		return err
	}
	res, err := s.db.Exec(`DELETE FROM users WHERE id = ?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetUserHash sets a password by username. It also re-enables the account, so the
// "ipvexa-server passwd" command can always recover access.
func (s *Store) SetUserHash(username, hash string) error {
	res, err := s.db.Exec(`UPDATE users SET hash = ?, disabled = 0 WHERE username = ? COLLATE NOCASE`, hash, username)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) SetUserHashByID(id int64, hash string) error {
	res, err := s.db.Exec(`UPDATE users SET hash = ? WHERE id = ?`, hash, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) TouchLogin(id int64) {
	s.db.Exec(`UPDATE users SET last_login = ? WHERE id = ?`, time.Now().UnixMilli(), id)
}

func (s *Store) UserByName(name string) (User, error) {
	// Usernames are case-insensitive ("Admin" = "admin").
	return scanUser(s.db.QueryRow(`SELECT `+userCols+` FROM users WHERE username = ? COLLATE NOCASE`, name))
}

func (s *Store) UserByID(id int64) (User, error) {
	return scanUser(s.db.QueryRow(`SELECT `+userCols+` FROM users WHERE id = ?`, id))
}

func (s *Store) NewSession(userID int64, ttl time.Duration) (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	tok := hex.EncodeToString(b)
	_, err := s.db.Exec(`INSERT INTO sessions (token, user_id, expires) VALUES (?,?,?)`, tok, userID, time.Now().Add(ttl).UnixMilli())
	return tok, err
}

func (s *Store) SessionUser(token string) (User, error) {
	var uid int64
	err := s.db.QueryRow(`SELECT user_id FROM sessions WHERE token = ? AND expires > ?`, token, time.Now().UnixMilli()).Scan(&uid)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrNotFound
	}
	if err != nil {
		return User{}, err
	}
	return s.UserByID(uid)
}

func (s *Store) DeleteSession(token string) error {
	_, err := s.db.Exec(`DELETE FROM sessions WHERE token = ?`, token)
	return err
}

// DeleteUserSessions signs a user out everywhere except the given session token.
func (s *Store) DeleteUserSessions(userID int64, keepToken string) error {
	_, err := s.db.Exec(`DELETE FROM sessions WHERE user_id = ? AND token != ?`, userID, keepToken)
	return err
}

func (s *Store) PurgeSessions() {
	s.db.Exec(`DELETE FROM sessions WHERE expires < ?`, time.Now().UnixMilli())
}
