package ml

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/proyecto-g7/transporte/internal/features"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSnapshotCacheRejectsChangedBytes(t *testing.T) {
	origin := time.Date(2024, 1, 1, 5, 15, 0, 0, time.UTC)
	row := features.Example{ZoneID: 161, Origin: origin, TargetStart: origin, HourCos: 1, Lag1: 7, Target: 8, Split: "train"}
	raw, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "snapshot.ndjson")
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(raw)
	checksum := hex.EncodeToString(sum[:])
	for i := 0; i < 2; i++ {
		rows, err := LoadSnapshot(context.Background(), path, checksum)
		if err != nil || len(rows) != 1 || rows[0].Target != 8 {
			t.Fatalf("load: %v, %v", rows, err)
		}
	}
	// The cached row must never hide a later modification of the underlying file.
	row.Target = 9
	raw, _ = json.Marshal(row)
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadSnapshot(context.Background(), path, checksum); err == nil {
		t.Fatal("cache accepted modified snapshot")
	}
}
