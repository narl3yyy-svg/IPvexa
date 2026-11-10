//go:build !linux

package timesync

func clockSynced() bool { return true }
