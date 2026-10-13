package ml

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/features"
	"io"
	"os"
	"sync"
)

var snapshotCache struct {
	sync.Mutex
	path, sha string
	rows      []features.Example
}

type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (r contextReader) Read(b []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.r.Read(b)
}

// Cached rows are immutable. Revalidate bytes before reuse; never trust mtime alone.
func LoadSnapshot(ctx context.Context, path, checksum string) ([]features.Example, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	h := sha256.New()
	_, err = io.Copy(h, contextReader{ctx, f})
	f.Close()
	if err != nil {
		return nil, err
	}
	if hex.EncodeToString(h.Sum(nil)) != checksum {
		return nil, fmt.Errorf("snapshot checksum mismatch")
	}
	snapshotCache.Lock()
	defer snapshotCache.Unlock()
	if snapshotCache.path == path && snapshotCache.sha == checksum {
		return snapshotCache.rows, nil
	}
	rows, err := ReadSnapshot(ctx, path, checksum)
	if err != nil {
		return nil, err
	}
	snapshotCache.path = path
	snapshotCache.sha = checksum
	snapshotCache.rows = rows
	return rows, nil
}
