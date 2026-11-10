package timesync

import "golang.org/x/sys/unix"

// clockSynced reports whether the kernel considers the system clock synchronised
// (e.g. by systemd-timesyncd or chrony).
func clockSynced() bool {
	var tx unix.Timex
	state, err := unix.Adjtimex(&tx)
	return err == nil && state != unix.TIME_ERROR && tx.Status&unix.STA_UNSYNC == 0
}
