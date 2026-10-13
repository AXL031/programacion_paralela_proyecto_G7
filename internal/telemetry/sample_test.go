package telemetry

import (
	"context"
	"runtime"
	"testing"
	"time"
)

func TestRealProcessSample(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := New(ctx)
	if runtime.GOOS != "linux" {
		t.Skip("resident memory is measured on Linux deployment")
	}
	sample := m.Sample()
	if !sample.Valid() || !sample.Available || sample.RSSBytes == 0 || sample.HeapBytes == 0 {
		t.Fatalf("missing real process metrics: %+v", sample)
	}
	start := sample.At
	deadline := time.Now().Add(3 * time.Second)
	for m.Sample().At.Equal(start) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	sample = m.Sample()
	if !sample.Valid() || sample.At.Equal(start) {
		t.Fatal("monitor did not update")
	}
}
