//go:build !linux && !darwin

package ai

import "errors"

type ortLib struct{}

type ortSession struct{}

func loadORT(string) (*ortLib, error) {
	return nil, errors.New("object detection is only available on Linux and macOS")
}

func (o *ortLib) newSession(string, int) (*ortSession, error) {
	return nil, errors.New("not available")
}

func (s *ortSession) run([]float32, []int64) ([]float32, []int64, error) {
	return nil, nil, errors.New("not available")
}

func (s *ortSession) close() {}
