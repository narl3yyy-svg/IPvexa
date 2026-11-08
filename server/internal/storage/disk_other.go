//go:build !unix

package storage

type DiskUsage struct {
	Total uint64 `json:"total"`
	Free  uint64 `json:"free"`
}

// Windows support comes later; report "unknown" so retention only uses age limits.
func Usage(path string) (DiskUsage, error) { return DiskUsage{}, nil }

func FreePct(path string) (float64, error) { return 100, nil }
