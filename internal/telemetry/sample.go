package telemetry

import (
	"context"
	"math"
	"sync/atomic"
	"time"
)

type Sample struct {
	At         time.Time `json:"sampled_at"`
	CPUPercent float64   `json:"cpu_percent"`
	RSSBytes   uint64    `json:"rss_bytes"`
	HeapBytes  uint64    `json:"heap_bytes"`
	Available  bool      `json:"available"`
}

func (s Sample) Valid() bool {
	return !s.At.IsZero() && !math.IsNaN(s.CPUPercent) && !math.IsInf(s.CPUPercent, 0) && s.CPUPercent >= 0 && s.CPUPercent <= 100000
}

type Monitor struct{ current atomic.Pointer[Sample] }

func New(ctx context.Context) *Monitor {
	m := &Monitor{}
	sample, previousCPU := processSample()
	m.current.Store(&sample)
	previousTime := time.Now()
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				next, cpu := processSample()
				elapsed := now.Sub(previousTime).Seconds()
				if elapsed > 0 && cpu >= previousCPU {
					next.CPUPercent = 100 * (cpu - previousCPU) / elapsed
				}
				m.current.Store(&next)
				previousCPU = cpu
				previousTime = now
			}
		}
	}()
	return m
}
func (m *Monitor) Sample() Sample {
	if m == nil {
		return Sample{}
	}
	return *m.current.Load()
}
