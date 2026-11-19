package store

import (
	"fmt"
	"path/filepath"
	"testing"
)

func TestDays(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "d.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	const day = int64(86400000)
	d0 := int64(1_700_000_000_000)
	seg := func(stream string, a, b int64) {
		if err := db.AddSegment(&Segment{CameraID: 1, Stream: stream, Path: fmt.Sprintf("/x/%s-%d", stream, a), Start: a, End: b, Size: 1}); err != nil {
			t.Fatal(err)
		}
	}
	// Day 0: 10 minutes from 01:00. A minute crosses into day 1 (30 s each side).
	for m := int64(0); m < 10; m++ {
		seg("main", d0+3600000+m*60000, d0+3600000+(m+1)*60000)
	}
	seg("main", d0+day-30000, d0+day+30000)
	// Day 1: a little substream only; day 2: nothing.
	seg("sub", d0+day+7200000, d0+day+7260000)
	// Another camera's footage must not count.
	if err := db.AddSegment(&Segment{CameraID: 2, Stream: "main", Path: "/y", Start: d0 + 2*day + 1000, End: d0 + 2*day + 61000}); err != nil {
		t.Fatal(err)
	}
	for _, s := range []int64{d0 + 3600000, d0 + 3700000, d0 + day + 5} {
		if err := db.AddEvent(&Event{CameraID: 1, Kind: "motion", Start: s, End: s + 1000}); err != nil {
			t.Fatal(err)
		}
	}
	db.AddEvent(&Event{CameraID: 1, Kind: "bookmark", Start: d0 + 5000, End: d0 + 6000})

	got, err := db.Days(1, []int64{d0, d0 + day, d0 + 2*day, d0 + 3*day})
	if err != nil {
		t.Fatal(err)
	}
	want := []DaySummary{
		{Start: d0, Recorded: 600000 + 30000, First: d0 + 3600000, Motion: 2},
		{Start: d0 + day, Recorded: 60000, First: d0 + day + 7200000, Motion: 1},
		{Start: d0 + 2*day},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d days, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("day %d: got %+v, want %+v", i, got[i], want[i])
		}
	}
}
