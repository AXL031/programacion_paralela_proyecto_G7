package training

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/proyecto-g7/transporte/internal/ml"
)

// DiagnosticsSchema identifies the benchmark-facing candidate evidence format.
const DiagnosticsSchema = "candidate-diagnostics-v1"

var sampleIDPattern = regexp.MustCompile(`^[a-zA-Z0-9-]+$`)

// Candidate is the trained SGD result captured before ml.Select. It is kept
// separate from Artifact so diagnostics never become part of the published
// model or the public prediction contract.
type Candidate struct {
	RunID              string         `json:"run_id"`
	Mode               string         `json:"mode"`
	DatasetID          string         `json:"dataset_id"`
	SnapshotSHA256     string         `json:"snapshot_sha256"`
	Encoder            ml.Encoder     `json:"encoder"`
	Config             ml.Config      `json:"config"`
	Seed               int64          `json:"seed"`
	TrainExamples      int            `json:"train_examples"`
	ValidationExamples int            `json:"validation_examples"`
	TestExamples       int            `json:"test_examples"`
	Dimension          int            `json:"dimension"`
	TotalSteps         int            `json:"total_steps"`
	Workers            []string       `json:"workers"`
	TasksByWorker      map[string]int `json:"tasks_by_worker"`
	Weights            []float64      `json:"weights"`
	Validation         ml.Metrics     `json:"validation"`
	Selection          ml.Selection   `json:"selection"`
	LossHistory        []float64      `json:"loss_history"`
	CreatedAt          time.Time      `json:"created_at"`
}

// Diagnostics is the optional, benchmark-only evidence written next to a run.
// reference_weights identify the effective sequential reference; candidate
// weights are compared before selection, never through the published model.
type Diagnostics struct {
	SchemaVersion string `json:"schema_version"`
	SampleID      string `json:"sample_id"`
	RunID         string `json:"run_id"`
	Mode          string `json:"mode"`
	DatasetID     string `json:"dataset_id"`

	SnapshotSHA256 string    `json:"snapshot_sha256"`
	EncoderVersion string    `json:"encoder_version"`
	EncoderSHA256  string    `json:"encoder_sha256"`
	Seed           int64     `json:"seed"`
	Config         ml.Config `json:"config"`

	TrainExamples      int `json:"train_examples"`
	ValidationExamples int `json:"validation_examples"`
	TestExamples       int `json:"test_examples"`
	Dimension          int `json:"dimension"`
	TotalSteps         int `json:"total_steps"`

	Workers       []string       `json:"workers"`
	TasksByWorker map[string]int `json:"tasks_by_worker"`

	ReferenceRunID   string    `json:"reference_run_id,omitempty"`
	ReferenceMode    string    `json:"reference_mode,omitempty"`
	ReferenceWeights []float64 `json:"reference_weights"`
	CandidateWeights []float64 `json:"candidate_weights"`

	ReferenceValidation ml.Metrics `json:"reference_validation"`
	CandidateValidation ml.Metrics `json:"candidate_validation"`

	CandidateMaxDifference float64 `json:"candidate_max_difference"`
	AbsoluteTolerance      float64 `json:"absolute_tolerance"`
	RelativeTolerance      float64 `json:"relative_tolerance"`
	Equivalent             bool    `json:"equivalent"`

	Selection              ml.Selection `json:"selection"`
	LossHistory            []float64    `json:"loss_history"`
	PublishedWeightsSHA256 string       `json:"published_weights_sha256,omitempty"`
	CreatedAt              time.Time    `json:"created_at"`
}

// DiagnosticsSummary is printed by the trainer so adapters can locate and hash
// the evidence without parsing the whole file.
type DiagnosticsSummary struct {
	Path                   string  `json:"path"`
	SHA256                 string  `json:"sha256"`
	SampleID               string  `json:"sample_id"`
	CandidateMaxDifference float64 `json:"candidate_max_difference"`
	AbsoluteTolerance      float64 `json:"absolute_tolerance"`
	RelativeTolerance      float64 `json:"relative_tolerance"`
	Equivalent             bool    `json:"equivalent"`
	ReferenceRunID         string  `json:"reference_run_id,omitempty"`
}

func ValidateSampleID(id string) error {
	if id == "" || len(id) > 128 || !sampleIDPattern.MatchString(id) {
		return fmt.Errorf("sample id must match ^[a-zA-Z0-9-]+$")
	}
	return nil
}

func NewDiagnostics(c Candidate, sampleID string) (Diagnostics, error) {
	if err := ValidateSampleID(sampleID); err != nil {
		return Diagnostics{}, err
	}
	if c.RunID == "" || c.DatasetID == "" || len(c.SnapshotSHA256) != 64 {
		return Diagnostics{}, fmt.Errorf("invalid candidate identity")
	}
	if c.Encoder.Version == "" || c.Dimension <= 0 || len(c.Weights) != c.Dimension {
		return Diagnostics{}, fmt.Errorf("invalid candidate dimensions")
	}
	if c.Dimension != c.Encoder.Dimension() {
		return Diagnostics{}, fmt.Errorf("candidate dimension does not match encoder")
	}
	for _, w := range c.Weights {
		if !ml.Finite(w) {
			return Diagnostics{}, fmt.Errorf("non-finite candidate weight")
		}
	}
	for _, l := range c.LossHistory {
		if !ml.Finite(l) || l < 0 {
			return Diagnostics{}, fmt.Errorf("invalid loss history")
		}
	}
	encoderHash, err := EncoderSHA256(c.Encoder)
	if err != nil {
		return Diagnostics{}, err
	}
	created := c.CreatedAt
	if created.IsZero() {
		created = time.Now().UTC()
	}
	workers := append([]string{}, c.Workers...)
	tasks := map[string]int{}
	for k, v := range c.TasksByWorker {
		tasks[k] = v
	}
	d := Diagnostics{
		SchemaVersion:       DiagnosticsSchema,
		SampleID:            sampleID,
		RunID:               c.RunID,
		Mode:                c.Mode,
		DatasetID:           c.DatasetID,
		SnapshotSHA256:      c.SnapshotSHA256,
		EncoderVersion:      c.Encoder.Version,
		EncoderSHA256:       encoderHash,
		Seed:                c.Seed,
		Config:              c.Config,
		TrainExamples:       c.TrainExamples,
		ValidationExamples:  c.ValidationExamples,
		TestExamples:        c.TestExamples,
		Dimension:           c.Dimension,
		TotalSteps:          c.TotalSteps,
		Workers:             workers,
		TasksByWorker:       tasks,
		CandidateWeights:    append([]float64{}, c.Weights...),
		CandidateValidation: c.Validation,
		Selection:           c.Selection,
		LossHistory:         append([]float64{}, c.LossHistory...),
		CreatedAt:           created,
	}
	return d, nil
}

// SetSelfReference marks the sequential run as its own effective reference.
func (d *Diagnostics) SetSelfReference(absolute, relative float64) error {
	if err := validateTolerances(absolute, relative); err != nil {
		return err
	}
	d.ReferenceRunID = d.RunID
	d.ReferenceMode = d.Mode
	d.ReferenceWeights = append([]float64{}, d.CandidateWeights...)
	d.ReferenceValidation = d.CandidateValidation
	d.CandidateMaxDifference = 0
	d.AbsoluteTolerance = absolute
	d.RelativeTolerance = relative
	d.Equivalent = true
	return nil
}

// SetReference attaches a sequential reference and applies the agreed
// per-parameter tolerance. A numeric divergence is recorded as
// equivalent=false; incompatible inputs are rejected as errors.
func (d *Diagnostics) SetReference(reference Diagnostics, absolute, relative float64) error {
	if reference.SchemaVersion != DiagnosticsSchema {
		return fmt.Errorf("unsupported reference diagnostics schema %q", reference.SchemaVersion)
	}
	if err := validateTolerances(absolute, relative); err != nil {
		return err
	}
	if reference.DatasetID != d.DatasetID {
		return fmt.Errorf("reference dataset differs: %s != %s", reference.DatasetID, d.DatasetID)
	}
	if reference.SnapshotSHA256 != d.SnapshotSHA256 {
		return fmt.Errorf("reference snapshot differs")
	}
	if reference.EncoderSHA256 != d.EncoderSHA256 || reference.EncoderVersion != d.EncoderVersion {
		return fmt.Errorf("reference encoder differs")
	}
	if reference.Seed != d.Seed {
		return fmt.Errorf("reference seed differs")
	}
	if err := compareConfig(reference.Config, d.Config); err != nil {
		return err
	}
	if reference.TrainExamples != d.TrainExamples || reference.ValidationExamples != d.ValidationExamples || reference.TestExamples != d.TestExamples {
		return fmt.Errorf("reference train/validation/test splits differ")
	}
	if reference.Dimension != d.Dimension || len(reference.CandidateWeights) != d.Dimension {
		return fmt.Errorf("reference dimensions differ")
	}
	maxDifference, equivalent, err := CompareWeights(reference.CandidateWeights, d.CandidateWeights, absolute, relative)
	if err != nil {
		return err
	}
	d.ReferenceRunID = reference.RunID
	d.ReferenceMode = reference.Mode
	d.ReferenceWeights = append([]float64{}, reference.CandidateWeights...)
	d.ReferenceValidation = reference.CandidateValidation
	d.CandidateMaxDifference = maxDifference
	d.AbsoluteTolerance = absolute
	d.RelativeTolerance = relative
	d.Equivalent = equivalent
	return nil
}

func compareConfig(reference, candidate ml.Config) error {
	if reference.Epochs != candidate.Epochs {
		return fmt.Errorf("reference epochs differ")
	}
	if reference.BatchSize != candidate.BatchSize {
		return fmt.Errorf("reference batch size differs")
	}
	if reference.LearningRate != candidate.LearningRate {
		return fmt.Errorf("reference learning rate differs")
	}
	if reference.L2 != candidate.L2 {
		return fmt.Errorf("reference l2 differs")
	}
	return nil
}

func validateTolerances(absolute, relative float64) error {
	if !ml.Finite(absolute) || !ml.Finite(relative) || absolute < 0 || relative < 0 {
		return fmt.Errorf("tolerances must be finite and non-negative")
	}
	return nil
}

// CompareWeights applies the agreed per-parameter tolerance:
//
//	abs(a-b) <= absolute + relative*max(abs(a),abs(b))
func CompareWeights(reference, candidate []float64, absolute, relative float64) (float64, bool, error) {
	if err := validateTolerances(absolute, relative); err != nil {
		return 0, false, err
	}
	if len(reference) == 0 || len(reference) != len(candidate) {
		return 0, false, fmt.Errorf("weight dimensions differ")
	}
	maxDifference := 0.0
	equivalent := true
	for i := range reference {
		a, b := reference[i], candidate[i]
		if !ml.Finite(a) || !ml.Finite(b) {
			return 0, false, fmt.Errorf("non-finite weight at index %d", i)
		}
		delta := absFloat(a - b)
		if delta > maxDifference {
			maxDifference = delta
		}
		limit := absolute + relative*maxFloat(absFloat(a), absFloat(b))
		if delta > limit {
			equivalent = false
		}
	}
	return maxDifference, equivalent, nil
}

// Validate checks identity, dimensions and that the recorded comparison is
// internally consistent with its weights and tolerances.
func (d Diagnostics) Validate() error {
	if d.SchemaVersion != DiagnosticsSchema {
		return fmt.Errorf("invalid diagnostics schema")
	}
	if err := ValidateSampleID(d.SampleID); err != nil {
		return err
	}
	if d.RunID == "" || d.DatasetID == "" || d.Mode == "" {
		return fmt.Errorf("invalid diagnostics identity")
	}
	if len(d.SnapshotSHA256) != 64 || len(d.EncoderSHA256) != 64 {
		return fmt.Errorf("invalid diagnostics hashes")
	}
	if d.Dimension <= 0 || len(d.CandidateWeights) != d.Dimension || len(d.ReferenceWeights) != d.Dimension {
		return fmt.Errorf("invalid diagnostics dimensions")
	}
	if d.Selection.Method == "" {
		return fmt.Errorf("missing selection method")
	}
	if err := validateTolerances(d.AbsoluteTolerance, d.RelativeTolerance); err != nil {
		return err
	}
	maxDifference, equivalent, err := CompareWeights(d.ReferenceWeights, d.CandidateWeights, d.AbsoluteTolerance, d.RelativeTolerance)
	if err != nil {
		return err
	}
	if maxDifference != d.CandidateMaxDifference {
		return fmt.Errorf("candidate maximum difference does not match weights")
	}
	if equivalent != d.Equivalent {
		return fmt.Errorf("candidate equivalence declaration does not match weights")
	}
	return nil
}

func ReadDiagnostics(path string) (Diagnostics, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Diagnostics{}, err
	}
	var d Diagnostics
	if err := json.Unmarshal(b, &d); err != nil {
		return Diagnostics{}, fmt.Errorf("invalid diagnostics JSON: %w", err)
	}
	if err := d.Validate(); err != nil {
		return Diagnostics{}, err
	}
	return d, nil
}

// WriteDiagnostics writes the evidence atomically and returns its checksum.
func WriteDiagnostics(path string, d Diagnostics) (DiagnosticsSummary, error) {
	if err := d.Validate(); err != nil {
		return DiagnosticsSummary{}, err
	}
	b, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return DiagnosticsSummary{}, err
	}
	b = append(b, '\n')
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return DiagnosticsSummary{}, err
	}
	tmp, err := os.CreateTemp(dir, ".candidate-diagnostics-*.tmp")
	if err != nil {
		return DiagnosticsSummary{}, err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return DiagnosticsSummary{}, err
	}
	if err := tmp.Close(); err != nil {
		return DiagnosticsSummary{}, err
	}
	if err := os.Rename(tmpName, path); err != nil {
		// Windows refuses to replace an existing target.
		if removeErr := os.Remove(path); removeErr != nil && !os.IsNotExist(removeErr) {
			return DiagnosticsSummary{}, err
		}
		if err := os.Rename(tmpName, path); err != nil {
			return DiagnosticsSummary{}, err
		}
	}
	sum := sha256.Sum256(b)
	return DiagnosticsSummary{
		Path:                   path,
		SHA256:                 hex.EncodeToString(sum[:]),
		SampleID:               d.SampleID,
		CandidateMaxDifference: d.CandidateMaxDifference,
		AbsoluteTolerance:      d.AbsoluteTolerance,
		RelativeTolerance:      d.RelativeTolerance,
		Equivalent:             d.Equivalent,
		ReferenceRunID:         d.ReferenceRunID,
	}, nil
}

func EncoderSHA256(e ml.Encoder) (string, error) {
	b, err := json.Marshal(e)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

func WeightsSHA256(weights []float64) (string, error) {
	b, err := json.Marshal(weights)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

func absFloat(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}

func maxFloat(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}
