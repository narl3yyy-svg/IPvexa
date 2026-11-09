package camera

import (
	"os"
	"path/filepath"
	"testing"

	"ipvexa/internal/store"
)

func TestCheckRoot(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "disk2", "ipvexa")
	if err := CheckRoot(dir); err != nil {
		t.Fatalf("a new folder should be created: %v", err)
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		t.Fatal("folder not created")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Error("the write test left a file behind")
	}
	if CheckRoot("relative/path") == nil {
		t.Error("a relative path must be refused")
	}
}

// Segments recorded before the folder moved keep relative paths under the
// original root; newer ones store their full path.
func TestSegmentFile(t *testing.T) {
	orig := filepath.Join(t.TempDir(), "recordings")
	old := store.Segment{Path: filepath.Join("3", "main", "2026", "11", "08", "1.mp4")}
	if got := old.File(orig); got != filepath.Join(orig, old.Path) {
		t.Errorf("relative path: %s", got)
	}
	abs := filepath.Join(t.TempDir(), "disk2", "3", "main", "1.mp4")
	if got := (store.Segment{Path: abs}).File(orig); got != abs {
		t.Errorf("absolute path: %s", got)
	}
}
