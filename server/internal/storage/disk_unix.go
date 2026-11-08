//go:build unix

package storage

import "syscall"

type DiskUsage struct {
	Total uint64 `json:"total"`
	Free  uint64 `json:"free"`
}

func Usage(path string) (DiskUsage, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return DiskUsage{}, err
	}
	bs := uint64(st.Bsize)
	return DiskUsage{Total: st.Blocks * bs, Free: st.Bavail * bs}, nil
}

func FreePct(path string) (float64, error) {
	u, err := Usage(path)
	if err != nil || u.Total == 0 {
		return 100, err
	}
	return float64(u.Free) * 100 / float64(u.Total), nil
}
