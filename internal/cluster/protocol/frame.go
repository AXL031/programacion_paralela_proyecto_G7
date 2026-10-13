package protocol

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/domain"
	"github.com/proyecto-g7/transporte/internal/ml"
	"github.com/proyecto-g7/transporte/internal/telemetry"
	"io"
	"net"
	"sync"
	"time"
)

const Version = 1
const MaxFrame = 4 * 1024 * 1024

type Message struct {
	Type         string            `json:"type"`
	Protocol     int               `json:"protocol"`
	WorkerID     string            `json:"worker_id,omitempty"`
	Session      string            `json:"session,omitempty"`
	RunID        string            `json:"run_id,omitempty"`
	Step         int               `json:"step"`
	TaskID       int               `json:"task_id"`
	Attempt      int               `json:"attempt"`
	ModelVersion int               `json:"model_version"`
	Manifest     *domain.Manifest  `json:"manifest,omitempty"`
	Encoder      *ml.Encoder       `json:"encoder,omitempty"`
	Weights      []float64         `json:"weights,omitempty"`
	Indices      []int             `json:"indices,omitempty"`
	Gradient     *ml.Gradient      `json:"gradient,omitempty"`
	Count        int               `json:"count,omitempty"`
	Error        string            `json:"error,omitempty"`
	Telemetry    *telemetry.Sample `json:"telemetry,omitempty"`
}

func Write(w io.Writer, m Message) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	if len(b) > MaxFrame {
		return fmt.Errorf("frame too large")
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(b)))
	if err := writeAll(w, header[:]); err != nil {
		return err
	}
	return writeAll(w, b)
}
func writeAll(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if err != nil {
			return err
		}
		if n <= 0 {
			return io.ErrShortWrite
		}
		b = b[n:]
	}
	return nil
}
func Read(r io.Reader) (Message, error) {
	var m Message
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return m, err
	}
	n := binary.BigEndian.Uint32(header[:])
	if n == 0 || n > MaxFrame {
		return m, fmt.Errorf("invalid frame length %d", n)
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		return m, err
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return m, err
	}
	if m.Protocol != Version {
		return m, fmt.Errorf("unsupported protocol version")
	}
	return m, nil
}

type Stream struct {
	Conn net.Conn
	mu   sync.Mutex
}

func (s *Stream) Send(m Message) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.Conn.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return err
	}
	m.Protocol = Version
	return Write(s.Conn, m)
}
func (s *Stream) Receive(timeout time.Duration) (Message, error) {
	if err := s.Conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return Message{}, err
	}
	return Read(s.Conn)
}
