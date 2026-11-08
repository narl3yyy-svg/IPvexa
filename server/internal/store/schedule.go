package store

import (
	"errors"
	"slices"
	"time"
)

// ScheduleRule switches a camera's recording mode during a weekly time window,
// e.g. "motion only on weekdays 08:00–18:00". The first matching rule wins; outside
// every rule the camera's RecordMode applies.
type ScheduleRule struct {
	Days []int  `json:"days"` // 0 = Sunday … 6; empty = every day
	From string `json:"from"` // "HH:MM"
	To   string `json:"to"`   // "HH:MM"; earlier than From = overnight
	Mode string `json:"mode"` // off | continuous | motion
}

var RecordModes = []string{"off", "continuous", "motion"}

func clockMinutes(s string) (int, error) {
	t, err := time.Parse("15:04", s)
	if err != nil {
		return 0, err
	}
	return t.Hour()*60 + t.Minute(), nil
}

// Validate checks a rule.
func (r ScheduleRule) Validate() error {
	if !slices.Contains(RecordModes, r.Mode) {
		return errors.New("schedule: mode must be off, continuous or motion")
	}
	from, err1 := clockMinutes(r.From)
	to, err2 := clockMinutes(r.To)
	if err1 != nil || err2 != nil {
		return errors.New("schedule: times must look like 22:30")
	}
	if from == to {
		return errors.New("schedule: the start and end times are the same")
	}
	for _, d := range r.Days {
		if d < 0 || d > 6 {
			return errors.New("schedule: days are 0 (Sunday) to 6 (Saturday)")
		}
	}
	return nil
}

// Covers reports whether t falls in the rule's window. An overnight window belongs
// to the day it starts on.
func (r ScheduleRule) Covers(t time.Time) bool {
	from, err1 := clockMinutes(r.From)
	to, err2 := clockMinutes(r.To)
	if err1 != nil || err2 != nil {
		return false
	}
	dayOK := func(d time.Weekday) bool { return len(r.Days) == 0 || slices.Contains(r.Days, int(d)) }
	now := t.Hour()*60 + t.Minute()
	switch {
	case from < to:
		return dayOK(t.Weekday()) && now >= from && now < to
	case now >= from:
		return dayOK(t.Weekday())
	case now < to:
		return dayOK(t.AddDate(0, 0, -1).Weekday())
	}
	return false
}

// ModeAt is the camera's recording mode at time t.
func (c Camera) ModeAt(t time.Time) string {
	for _, r := range c.RecordSchedule {
		if r.Covers(t) {
			return r.Mode
		}
	}
	return c.RecordMode
}

// UsesMode reports whether the camera records in mode m at any time.
func (c Camera) UsesMode(m string) bool {
	if c.RecordMode == m {
		return true
	}
	for _, r := range c.RecordSchedule {
		if r.Mode == m {
			return true
		}
	}
	return false
}
