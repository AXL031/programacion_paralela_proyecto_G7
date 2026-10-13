//go:build !linux

package telemetry

import (
	"runtime"
	"time"
)

func processSample() (Sample, float64) {
	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)
	return Sample{At: time.Now().UTC(), HeapBytes: mem.HeapAlloc}, 0
}
