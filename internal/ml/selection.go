package ml

type Selection struct {
	Method              string  `json:"method"`
	Blend               float64 `json:"candidate_blend"`
	CandidateValidation Metrics `json:"candidate_validation"`
	SelectedValidation  Metrics `json:"selected_validation"`
	BaselineValidation  Metrics `json:"baseline_validation"`
}

// Select uses validation only. Baseline is an explicit candidate, never a silent replacement.
func Select(rows []Row, e Encoder, candidate []float64) ([]float64, Selection, error) {
	initial := Initial(e)
	base, err := Evaluate(rows, initial)
	if err != nil {
		return nil, Selection{}, err
	}
	cand, err := Evaluate(rows, candidate)
	if err != nil {
		return nil, Selection{}, err
	}
	s := Selection{Method: "persistence", CandidateValidation: cand.Model, SelectedValidation: base.Model, BaselineValidation: base.PersistenceBaseline}
	best := initial
	for _, alpha := range []float64{0.1, 0.25, 0.5, 0.75, 1} {
		w := make([]float64, len(initial))
		for i := range w {
			w[i] = initial[i] + alpha*(candidate[i]-initial[i])
		}
		v, err := Evaluate(rows, w)
		if err != nil {
			return nil, s, err
		}
		if v.Model.MAE < s.SelectedValidation.MAE-1e-10 && v.Model.RMSE <= s.BaselineValidation.RMSE+1e-10 {
			best = w
			s.Blend = alpha
			s.Method = "validated_sgd"
			s.SelectedValidation = v.Model
		}
	}
	return best, s, nil
}
