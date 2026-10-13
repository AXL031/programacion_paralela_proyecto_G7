package files

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/domain"
	"os"
	"path/filepath"
)

type Store struct {
	Root   string
	f      *os.File
	writer *bufio.Writer
	lock   string
}

func (s *Store) FindComplete(ctx context.Context, id string) (*domain.Manifest, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(s.Root, id, "manifest.json"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var m domain.Manifest
	if err = json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	if m.Status != "complete" {
		return nil, nil
	}
	return &m, nil
}

func (s *Store) Begin(ctx context.Context, m domain.Manifest) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	dir := filepath.Join(s.Root, m.ID)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	lock := filepath.Join(dir, "loading.lock")
	f, err := os.OpenFile(lock, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return fmt.Errorf("dataset locked (another load or interrupted process): %w", err)
	}
	f.Close()
	s.lock = lock
	// Check again under the lock: another process may have completed meanwhile.
	if _, err := os.Stat(filepath.Join(dir, "manifest.json")); err == nil {
		return fmt.Errorf("dataset already published; rerun to reuse it")
	}
	dir = filepath.Join(dir, m.LoadID)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	s.f, err = os.Create(filepath.Join(dir, "trips.ndjson"))
	if err != nil {
		return err
	}
	s.writer = bufio.NewWriterSize(s.f, 256*1024)
	return nil
}

func (s *Store) WriteTrips(ctx context.Context, trips []domain.Trip) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	e := json.NewEncoder(s.writer)
	for _, t := range trips {
		if err := e.Encode(t); err != nil {
			return err
		}
	}
	return nil
}

// Window files are emitted by the feature exporter before publication.
func (s *Store) WriteWindows(ctx context.Context, _ []domain.Window) error { return ctx.Err() }

func WriteJSON(path string, v any) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".manifest-*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err := json.NewEncoder(f).Encode(v); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (s *Store) Complete(ctx context.Context, m domain.Manifest) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if s.writer == nil {
		return nil
	}
	if err := s.writer.Flush(); err != nil {
		return err
	}
	if err := s.f.Sync(); err != nil {
		return err
	}
	return WriteJSON(filepath.Join(s.Root, m.ID, "manifest.json"), m)
}
func (s *Store) Fail(_ context.Context, m domain.Manifest) error {
	return WriteJSON(filepath.Join(s.Root, m.ID, m.LoadID, "failed.json"), m)
}
func (s *Store) Close(_ context.Context) error {
	var err error
	if s.writer != nil {
		err = s.writer.Flush()
	}
	if s.f != nil {
		if e := s.f.Close(); err == nil {
			err = e
		}
	}
	if s.lock != "" {
		if e := os.Remove(s.lock); err == nil {
			err = e
		}
	}
	return err
}
