package master

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"github.com/proyecto-g7/transporte/internal/cluster/protocol"
	"github.com/proyecto-g7/transporte/internal/domain"
	"github.com/proyecto-g7/transporte/internal/ml"
	"github.com/proyecto-g7/transporte/internal/telemetry"
	"github.com/proyecto-g7/transporte/internal/training"
	"net"
	"sort"
	"sync"
	"time"
)

type Repository interface {
	training.Repo
	Current(context.Context) (*domain.Manifest, error)
	Ping(context.Context) error
	Model(context.Context, string) (training.Artifact, error)
	TrainingRun(context.Context, string) (training.Run, error)
}
type Peer struct {
	ID, Session string
	Stream      *protocol.Stream
	Replies     chan protocol.Message
	Done        chan struct{}
	LastSeen    time.Time
	Tasks       int
	Busy        bool
	Telemetry   telemetry.Sample
}
type WorkerInfo struct {
	ID        string           `json:"worker_id"`
	Session   string           `json:"-"`
	LastSeen  time.Time        `json:"last_seen"`
	Tasks     int              `json:"accepted_tasks"`
	Busy      bool             `json:"busy"`
	Telemetry telemetry.Sample `json:"telemetry"`
}
type Server struct {
	Repo     Repository
	mu       sync.Mutex
	peers    map[string]*Peer
	runs     map[string]training.Run
	active   string
	ctx      context.Context
	listener net.Listener
	Monitor  *telemetry.Monitor
	Secret   string
}

func New(ctx context.Context, repo Repository) *Server {
	return &Server{Repo: repo, ctx: ctx, peers: map[string]*Peer{}, runs: map[string]training.Run{}, Monitor: telemetry.New(ctx)}
}
func (s *Server) Serve(listener net.Listener) error {
	s.listener = listener
	stop := context.AfterFunc(s.ctx, func() {
		listener.Close()
		s.mu.Lock()
		defer s.mu.Unlock()
		for _, p := range s.peers {
			p.Stream.Conn.Close()
		}
	})
	defer stop()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if s.ctx.Err() != nil {
				return nil
			}
			return err
		}
		go s.register(conn)
	}
}
func (s *Server) register(conn net.Conn) {
	stream := &protocol.Stream{Conn: conn}
	defer conn.Close()
	m, err := stream.Receive(10 * time.Second)
	if err != nil || m.Type != "register" || m.WorkerID == "" || len(m.WorkerID) > 128 {
		return
	}
	var token [12]byte
	if _, err := rand.Read(token[:]); err != nil {
		return
	}
	p := &Peer{ID: m.WorkerID, Session: hex.EncodeToString(token[:]), Stream: stream, Replies: make(chan protocol.Message, 8), Done: make(chan struct{}), LastSeen: time.Now().UTC()}
	s.mu.Lock()
	if _, exists := s.peers[p.ID]; exists {
		s.mu.Unlock()
		return
	}
	if err := s.send(p, protocol.Message{Type: "registered"}); err != nil {
		s.mu.Unlock()
		return
	}
	s.peers[p.ID] = p
	s.mu.Unlock()
	defer func() {
		close(p.Done)
		s.mu.Lock()
		if s.peers[p.ID] == p {
			delete(s.peers, p.ID)
		}
		s.mu.Unlock()
	}()
	for {
		m, err := stream.Receive(10 * time.Second)
		if err != nil {
			return
		}
		if m.WorkerID != p.ID || m.Session != p.Session {
			return
		}
		s.mu.Lock()
		p.LastSeen = time.Now().UTC()
		if m.Telemetry != nil && m.Telemetry.Valid() {
			p.Telemetry = *m.Telemetry
		}
		s.mu.Unlock()
		if m.Type == "heartbeat" {
			if err := s.send(p, protocol.Message{Type: "heartbeat_ack"}); err != nil {
				return
			}
			continue
		}
		if m.Type != "ready" && m.Type != "gradient" && m.Type != "error" {
			return
		}
		select {
		case p.Replies <- m:
		default:
			return
		}
	}
}
func (s *Server) send(p *Peer, m protocol.Message) error {
	m.WorkerID = p.ID
	m.Session = p.Session
	return p.Stream.Send(m)
}
func (s *Server) Workers() []WorkerInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []WorkerInfo{}
	for _, p := range s.peers {
		out = append(out, WorkerInfo{ID: p.ID, Session: p.Session, LastSeen: p.LastSeen, Tasks: p.Tasks, Busy: p.Busy, Telemetry: p.Telemetry})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}
func (s *Server) Run(id string) (training.Run, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.runs[id]
	return r, ok
}
func (s *Server) Start(c ml.Config) (training.Run, error) {
	if err := c.Validate(); err != nil {
		return training.Run{}, err
	}
	s.mu.Lock()
	if s.active != "" {
		s.mu.Unlock()
		return training.Run{}, fmt.Errorf("another training is active")
	}
	if len(s.peers) < c.Workers {
		s.mu.Unlock()
		return training.Run{}, fmt.Errorf("need %d connected workers", c.Workers)
	}
	peers := make([]*Peer, 0, len(s.peers))
	for _, p := range s.peers {
		peers = append(peers, p)
	}
	sort.Slice(peers, func(i, j int) bool { return peers[i].ID < peers[j].ID })
	peers = peers[:c.Workers]
	id := training.NewID()
	r := training.Run{ID: id, Mode: "distributed", Status: "queued", Config: c, StartedAt: time.Now().UTC(), Tasks: map[string]int{}}
	s.active = id
	s.runs[id] = r
	for _, p := range peers {
		p.Busy = true
	}
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(s.ctx, 5*time.Second)
	err := s.Repo.SaveRun(ctx, r)
	cancel()
	if err != nil {
		s.mu.Lock()
		s.active = ""
		delete(s.runs, id)
		for _, p := range peers {
			p.Busy = false
		}
		s.mu.Unlock()
		return r, err
	}
	go s.execute(c, id, peers)
	return r, nil
}
func (s *Server) execute(c ml.Config, id string, peers []*Peer) {
	ctx, cancel := context.WithTimeout(s.ctx, 20*time.Minute)
	defer cancel()
	var a training.Artifact
	var r training.Run
	tasks := map[string]int{}
	m, err := s.Repo.Current(ctx)
	if err == nil && m == nil {
		err = fmt.Errorf("no completed dataset")
	}
	if err == nil {
		a, r, err = training.Execute(ctx, *m, c, id, "distributed", func(ctx context.Context, m domain.Manifest, e ml.Encoder, d ml.Dataset) (ml.Computer, []string, error) {
			ids := make([]string, len(peers))
			for i, p := range peers {
				ids[i] = p.ID
				tasks[p.ID] = 0
				if err := s.send(p, protocol.Message{Type: "prepare", RunID: id, Manifest: &m, Encoder: &e}); err != nil {
					return nil, nil, err
				}
			}
			prep, done := context.WithTimeout(ctx, 30*time.Second)
			defer done()
			for _, p := range peers {
				reply, err := await(prep, p)
				if err != nil {
					return nil, nil, err
				}
				if reply.Type != "ready" || reply.RunID != id || reply.Count != len(d.Train) {
					return nil, nil, fmt.Errorf("invalid prepare acknowledgement from %s", p.ID)
				}
			}
			compute := func(ctx context.Context, step int, w []float64, indices []int) (ml.Gradient, error) {
				stepCtx, done := context.WithTimeout(ctx, time.Duration(c.TaskTimeoutSeconds)*time.Second)
				defer done()
				expected := map[int]int{}
				for i, p := range peers {
					start, end := len(indices)*i/len(peers), len(indices)*(i+1)/len(peers)
					if start == end {
						continue
					}
					expected[i] = end - start
					if err := s.send(p, protocol.Message{Type: "task", RunID: id, Step: step, TaskID: i, Attempt: 1, ModelVersion: step, Weights: w, Indices: indices[start:end]}); err != nil {
						return ml.Gradient{}, err
					}
				}
				total := ml.Gradient{Sum: make([]float64, len(w))}
				for i, p := range peers {
					count, ok := expected[i]
					if !ok {
						continue
					}
					reply, err := await(stepCtx, p)
					if err != nil {
						return total, err
					}
					if reply.Type != "gradient" || reply.RunID != id || reply.Step != step || reply.ModelVersion != step || reply.TaskID != i || reply.Attempt != 1 || reply.Gradient == nil {
						return total, fmt.Errorf("stale/duplicate/invalid gradient from %s", p.ID)
					}
					g := *reply.Gradient
					if err := ml.ValidateGradient(g, len(w), count); err != nil {
						return total, err
					}
					for j, v := range g.Sum {
						total.Sum[j] += v
					}
					total.Count += g.Count
					total.LossSum += g.LossSum
					tasks[p.ID]++
					s.mu.Lock()
					p.Tasks++
					s.mu.Unlock()
					if err := s.send(p, protocol.Message{Type: "ack", RunID: id, Step: step, TaskID: i}); err != nil {
						return total, err
					}
				}
				return total, nil
			}
			return compute, ids, nil
		}, func(progress training.Run) {
			progress.Tasks = copyTasks(tasks)
			s.mu.Lock()
			s.runs[id] = progress
			s.mu.Unlock()
		})
	}
	if r.ID == "" {
		r = training.Run{ID: id, Mode: "distributed", Config: c, StartedAt: time.Now().UTC()}
	}
	if err == nil {
		err = s.Repo.Publish(ctx, a)
	}
	r.Status = "completed"
	r.CompletedAt = time.Now().UTC()
	r.ArtifactVersion = a.Version
	r.Tasks = copyTasks(tasks)
	if err != nil {
		r.Status = "failed"
		r.Error = err.Error()
		r.ArtifactVersion = ""
		for _, p := range peers {
			p.Stream.Conn.Close()
		}
	} else {
		for _, p := range peers {
			s.send(p, protocol.Message{Type: "stop", RunID: id})
		}
	}
	saveCtx, done := context.WithTimeout(context.Background(), 5*time.Second)
	if e := s.Repo.SaveRun(saveCtx, r); e != nil {
		r.Status = "failed"
		r.Error = "persist final run: " + e.Error()
	}
	done()
	s.mu.Lock()
	s.runs[id] = r
	s.active = ""
	for _, p := range peers {
		p.Busy = false
	}
	s.mu.Unlock()
}
func await(ctx context.Context, p *Peer) (protocol.Message, error) {
	select {
	case <-ctx.Done():
		return protocol.Message{}, fmt.Errorf("worker %s timeout/cancellation: %w", p.ID, ctx.Err())
	case <-p.Done:
		return protocol.Message{}, fmt.Errorf("worker %s disconnected", p.ID)
	case m := <-p.Replies:
		if m.Type == "error" {
			return m, fmt.Errorf("worker %s: %s", p.ID, m.Error)
		}
		return m, nil
	}
}
func copyTasks(tasks map[string]int) map[string]int {
	out := map[string]int{}
	for k, v := range tasks {
		out[k] = v
	}
	return out
}
