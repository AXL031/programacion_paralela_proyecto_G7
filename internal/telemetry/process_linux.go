package telemetry

import (
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func processSample() (Sample, float64) {
	s := Sample{At: time.Now().UTC()}
	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)
	s.HeapBytes = mem.HeapAlloc
	var usage syscall.Rusage
	err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage)
	cpu := float64(usage.Utime.Sec+usage.Stime.Sec) + float64(usage.Utime.Usec+usage.Stime.Usec)/1e6
	raw, readErr := os.ReadFile("/proc/self/status")
	if readErr == nil {
		for _, line := range strings.Split(string(raw), "\n") {
			if strings.HasPrefix(line, "VmRSS:") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					kb, e := strconv.ParseUint(fields[1], 10, 64)
					if e == nil {
						s.RSSBytes = kb * 1024
					}
				}
			}
		}
	}
	s.Available = err == nil && readErr == nil && s.RSSBytes > 0
	return s, cpu
}
