package worker

import (
	"context"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/cluster/protocol"
	"github.com/proyecto-g7/transporte/internal/ml"
	"github.com/proyecto-g7/transporte/internal/telemetry"
	"log/slog"
	"net"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
)

type Client struct {
	ID       string
	Address  string
	DataRoot string
	Ready    atomic.Bool
	Monitor  *telemetry.Monitor
}

func (c *Client) Run(ctx context.Context) error {
	if c.ID == "" {
		return fmt.Errorf("worker ID required")
	}
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		err := c.Connect(ctx)
		c.Ready.Store(false)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		slog.Warn("worker reconnecting", "worker", c.ID, "error", err)
		timer := time.NewTimer(time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}
func (c *Client) Connect(parent context.Context) error {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	conn, err := (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, "tcp", c.Address)
	if err != nil {
		return err
	}
	defer conn.Close()
	defer c.Ready.Store(false)
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	s := &protocol.Stream{Conn: conn}
	if err := s.Send(protocol.Message{Type: "register", WorkerID: c.ID}); err != nil {
		return err
	}
	ack, err := s.Receive(10 * time.Second)
	if err != nil {
		return err
	}
	if ack.Type != "registered" || ack.WorkerID != c.ID || ack.Session == "" {
		return fmt.Errorf("invalid registration acknowledgement")
	}
	session := ack.Session
	c.Ready.Store(true)
	send := func(m protocol.Message) error { m.WorkerID = c.ID; m.Session = session; return s.Send(m) }
	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				metrics := c.Monitor.Sample()
				if send(protocol.Message{Type: "heartbeat", Telemetry: &metrics}) != nil {
					cancel()
					return
				}
			}
		}
	}()
	var rows []ml.Row
	var runID string
	dimension := 0
	for {
		m, err := s.Receive(12 * time.Second)
		if err != nil {
			return err
		}
		if m.WorkerID != c.ID || m.Session != session {
			return fmt.Errorf("session mismatch")
		}
		switch m.Type {
		case "heartbeat_ack":
			continue
		case "prepare":
			if m.Manifest == nil || m.Encoder == nil || m.RunID == "" {
				return fmt.Errorf("invalid prepare")
			}
			root, err := filepath.Abs(c.DataRoot)
			if err != nil {
				return err
			}
			path, err := filepath.Abs(m.Manifest.Snapshot.Path)
			if err != nil {
				return err
			}
			rel, err := filepath.Rel(root, path)
			if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				return fmt.Errorf("snapshot outside data root")
			}
			examples, err := ml.LoadSnapshot(ctx, path, m.Manifest.Snapshot.SHA256)
			if err != nil {
				send(protocol.Message{Type: "error", RunID: m.RunID, Error: err.Error()})
				return err
			}
			data, err := ml.Prepare(examples, *m.Encoder)
			if err != nil {
				send(protocol.Message{Type: "error", RunID: m.RunID, Error: err.Error()})
				return err
			}
			rows = data.Train
			runID = m.RunID
			dimension = m.Encoder.Dimension()
			if err := send(protocol.Message{Type: "ready", RunID: runID, Count: len(rows)}); err != nil {
				return err
			}
		case "task":
			if runID == "" || m.RunID != runID || m.Step < 0 || m.ModelVersion != m.Step || m.Attempt != 1 || len(m.Weights) != dimension || len(m.Indices) == 0 {
				return fmt.Errorf("invalid task identity/dimension")
			}
			for _, w := range m.Weights {
				if !ml.Finite(w) {
					return fmt.Errorf("non-finite weights")
				}
			}
			g, err := ml.Compute(ctx, rows, m.Weights, m.Indices)
			if err != nil {
				send(protocol.Message{Type: "error", RunID: runID, Error: err.Error()})
				return err
			}
			if err := send(protocol.Message{Type: "gradient", RunID: runID, Step: m.Step, TaskID: m.TaskID, Attempt: m.Attempt, ModelVersion: m.ModelVersion, Gradient: &g}); err != nil {
				return err
			}
		case "ack":
			continue
		case "stop":
			if m.RunID == runID {
				rows = nil
				runID = ""
				dimension = 0
			}
		default:
			return fmt.Errorf("unexpected master message %q", m.Type)
		}
	}
}
