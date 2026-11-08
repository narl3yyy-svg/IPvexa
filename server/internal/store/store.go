// Package store holds Ipvexa's persistent state in a single SQLite database
// (WAL mode, so it survives power loss and lets readers and the writer run together).
package store

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
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
	RecordMode    string `json:"record_mode"` // "continuous" or "off"
	RecordSub     bool   `json:"record_sub"`
	RetentionDays int    `json:"retention_days"`
	Enabled       bool   `json:"enabled"`
	CreatedAt     int64  `json:"created_at"`
}

type Segment struct {
	ID       int64  `json:"id"`
	CameraID int64  `json:"camera_id"`
	Stream   string `json:"stream"` // "main" or "sub"
	Path     string `json:"-"`      // relative to the recordings root
	Start    int64  `json:"start"`  // unix ms
	End      int64  `json:"end"`    // unix ms
	Size     int64  `json:"size"`
}

type User struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
	Hash     string `json:"-"`
	Role     string `json:"role"` // admin | operator | viewer
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

const camCols = `id, name, brand, main_url, sub_url, transport, record_mode, record_sub, retention_days, enabled, created_at`

func scanCamera(r interface{ Scan(...any) error }) (Camera, error) {
	var c Camera
	err := r.Scan(&c.ID, &c.Name, &c.Brand, &c.MainURL, &c.SubURL, &c.Transport, &c.RecordMode, &c.RecordSub, &c.RetentionDays, &c.Enabled, &c.CreatedAt)
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

func (s *Store) Camera(id int64) (Camera, error) {
	c, err := scanCamera(s.db.QueryRow(`SELECT `+camCols+` FROM cameras WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

func (s *Store) CreateCamera(c *Camera) error {
	c.CreatedAt = time.Now().UnixMilli()
	res, err := s.db.Exec(`INSERT INTO cameras (name, brand, main_url, sub_url, transport, record_mode, record_sub, retention_days, enabled, created_at)
		VALUES (?,?,?,?,?,?,?,?,?,?)`, c.Name, c.Brand, c.MainURL, c.SubURL, c.Transport, c.RecordMode, c.RecordSub, c.RetentionDays, c.Enabled, c.CreatedAt)
	if err != nil {
		return err
	}
	c.ID, err = res.LastInsertId()
	return err
}

func (s *Store) UpdateCamera(c *Camera) error {
	res, err := s.db.Exec(`UPDATE cameras SET name=?, brand=?, main_url=?, sub_url=?, transport=?, record_mode=?, record_sub=?, retention_days=?, enabled=? WHERE id=?`,
		c.Name, c.Brand, c.MainURL, c.SubURL, c.Transport, c.RecordMode, c.RecordSub, c.RetentionDays, c.Enabled, c.ID)
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

func (s *Store) UserCount() (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n)
	return n, err
}

func (s *Store) CreateUser(u *User) error {
	res, err := s.db.Exec(`INSERT INTO users (username, hash, role) VALUES (?,?,?)`, u.Username, u.Hash, u.Role)
	if err != nil {
		return err
	}
	u.ID, err = res.LastInsertId()
	return err
}

func (s *Store) SetUserHash(username, hash string) error {
	res, err := s.db.Exec(`UPDATE users SET hash = ? WHERE username = ?`, hash, username)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) UserByName(name string) (User, error) {
	var u User
	// Usernames are case-insensitive ("Admin" = "admin").
	err := s.db.QueryRow(`SELECT id, username, hash, role FROM users WHERE username = ? COLLATE NOCASE`, name).Scan(&u.ID, &u.Username, &u.Hash, &u.Role)
	if errors.Is(err, sql.ErrNoRows) {
		return u, ErrNotFound
	}
	return u, err
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
	var u User
	err := s.db.QueryRow(`SELECT u.id, u.username, u.hash, u.role FROM sessions s JOIN users u ON u.id = s.user_id
		WHERE s.token = ? AND s.expires > ?`, token, time.Now().UnixMilli()).Scan(&u.ID, &u.Username, &u.Hash, &u.Role)
	if errors.Is(err, sql.ErrNoRows) {
		return u, ErrNotFound
	}
	return u, err
}

func (s *Store) DeleteSession(token string) error {
	_, err := s.db.Exec(`DELETE FROM sessions WHERE token = ?`, token)
	return err
}

func (s *Store) PurgeSessions() {
	s.db.Exec(`DELETE FROM sessions WHERE expires < ?`, time.Now().UnixMilli())
}
