package api

import (
	"testing"

	"ipvexa/internal/motion"
	"ipvexa/internal/store"
)

func TestEventsAndBookmarks(t *testing.T) {
	e := newEnv(t)
	for _, name := range []string{"one", "two"} {
		if err := e.db.CreateCamera(&store.Camera{Name: name, MainURL: "demo://pattern"}); err != nil {
			t.Fatal(err)
		}
	}
	var left, right motion.Cells
	left.Set(0)   // top-left cell
	right.Set(15) // top-right cell
	for _, ev := range []store.Event{
		{CameraID: 1, Kind: "motion", Start: 1000, End: 2000, Cells: left.String()},
		{CameraID: 1, Kind: "motion", Start: 5000, End: 6000, Cells: right.String()},
		{CameraID: 2, Kind: "motion", Start: 5000, End: 0, Cells: left.String()}, // ongoing
	} {
		ev := ev
		if err := e.db.AddEvent(&ev); err != nil {
			t.Fatal(err)
		}
	}
	list := func(token, query string) (int, int) {
		code, arr := e.list("/api/events?"+query, token)
		return code, len(arr)
	}
	if _, n := list(e.admin, "from=0&to=10000"); n != 3 {
		t.Errorf("all events: got %d, want 3", n)
	}
	if _, n := list(e.admin, "camera=1&from=4000&to=10000"); n != 1 {
		t.Errorf("time + camera filter: got %d, want 1", n)
	}
	if _, n := list(e.admin, "from=100000&to=200000"); n != 1 {
		t.Errorf("ongoing event overlaps later windows: got %d, want 1", n)
	}
	if _, n := list(e.admin, "from=0&to=10000&cells="+left.String()); n != 2 {
		t.Errorf("smart search (left area): got %d, want 2", n)
	}

	// Bookmarks: viewers with playback may add; only the author or an admin may edit.
	e.do("POST", "/api/users", e.admin, map[string]any{"username": "amy", "role": "viewer", "password": "amyspassword",
		"permissions": map[string]any{"all_cameras": true, "playback": true}})
	e.do("POST", "/api/users", e.admin, map[string]any{"username": "joe", "role": "viewer", "password": "joespassword",
		"permissions": map[string]any{"all_cameras": false, "cameras": []int{2}, "playback": true}})
	amy := e.login("amy", "amyspassword")
	joe := e.login("joe", "joespassword")
	code, bm := e.do("POST", "/api/cameras/1/bookmarks", amy, map[string]any{"start": 3000, "end": 4000, "note": " delivery "})
	if code != 201 || bm["note"] != "delivery" || bm["author"] != "amy" {
		t.Fatalf("add bookmark: %d %v", code, bm)
	}
	path := "/api/events/" + itoa(int(bm["id"].(float64)))
	if code, _ := e.do("PUT", path, joe, map[string]any{"note": "x"}); code != 404 {
		t.Errorf("edit bookmark on a camera you can't see: got %d, want 404", code)
	}
	if _, n := list(joe, "from=0&to=10000"); n != 1 {
		t.Errorf("joe sees only camera 2: got %d, want 1", n)
	}
	if code, out := e.do("PUT", path, amy, map[string]any{"note": "parcel"}); code != 200 || out["note"] != "parcel" {
		t.Errorf("author edits note: %d %v", code, out)
	}
	if code, _ := e.do("GET", "/api/cameras/1/export?from=1000&to=2000", amy, nil); code != 403 {
		t.Errorf("export without permission: got %d, want 403", code)
	}
	if code, _ := e.do("DELETE", path, e.admin, nil); code != 204 {
		t.Errorf("admin deletes bookmark: got %d, want 204", code)
	}
}
