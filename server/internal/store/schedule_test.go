package store

import (
	"testing"
	"time"
)

func TestModeAt(t *testing.T) {
	// 2026-11-01 is a Sunday.
	at := func(day, hh, mm int) time.Time { return time.Date(2026, 11, 1+day, hh, mm, 0, 0, time.Local) }
	c := Camera{RecordMode: "continuous", RecordSchedule: []ScheduleRule{
		{Days: []int{1, 2, 3, 4, 5}, From: "08:00", To: "18:00", Mode: "motion"},
		{From: "23:00", To: "06:00", Mode: "off"},
	}}
	cases := []struct {
		t    time.Time
		want string
	}{
		{at(1, 9, 0), "motion"},      // Monday working hours
		{at(1, 18, 0), "continuous"}, // end is exclusive
		{at(0, 9, 0), "continuous"},  // Sunday: no weekday rule
		{at(2, 23, 30), "off"},       // overnight, evening part
		{at(3, 5, 59), "off"},        // overnight, morning part
		{at(3, 6, 0), "continuous"},
	}
	for _, k := range cases {
		if got := c.ModeAt(k.t); got != k.want {
			t.Errorf("ModeAt(%s) = %s, want %s", k.t.Format("Mon 15:04"), got, k.want)
		}
	}
	if !c.UsesMode("motion") || !c.UsesMode("off") || c.UsesMode("bogus") {
		t.Error("UsesMode")
	}
	for _, bad := range []ScheduleRule{{From: "08:00", To: "09:00", Mode: "sometimes"}, {From: "8am", To: "09:00", Mode: "off"},
		{From: "08:00", To: "08:00", Mode: "off"}, {Days: []int{7}, From: "08:00", To: "09:00", Mode: "off"}} {
		if bad.Validate() == nil {
			t.Errorf("rule %+v should be rejected", bad)
		}
	}
}
