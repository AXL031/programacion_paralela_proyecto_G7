package api

import (
	"net/http"
	"sort"
)

func (r *Runtime) Impact() map[string]any {
	b := r.current.Load()
	if b == nil {
		return map[string]any{"ready": false}
	}
	boroughs := map[int]string{}
	totals := map[string]int64{}
	for _, zone := range b.Dataset.Zones {
		boroughs[zone.ID] = zone.Borough
	}
	var total int64
	for key, count := range b.counts {
		totals[boroughs[key.zone]] += count
		total += count
	}
	type item struct {
		Name  string  `json:"borough"`
		Count int64   `json:"observed_trips"`
		Share float64 `json:"share"`
	}
	items := []item{}
	for name, count := range totals {
		share := 0.0
		if total > 0 {
			share = float64(count) / float64(total)
		}
		items = append(items, item{name, count, share})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Count > items[j].Count })
	return map[string]any{"ready": true, "dataset_id": b.Dataset.ID, "total_observed_trips": total, "boroughs": items, "question": "¿Cómo anticipar la actividad de viajes registrada por zona e intervalo para apoyar la planificación del transporte?", "use": "Comparar zonas y horarios y evaluar pronósticos frente a una referencia temporal.", "limitation": "Viajes completados aceptados en Yellow Taxi. No mide demanda no atendida, disponibilidad de vehículos ni desigualdad de acceso."}
}
func attachImpact(mux *http.ServeMux, r *Runtime) {
	mux.HandleFunc("GET /api/v1/impact", func(w http.ResponseWriter, req *http.Request) { send(w, 200, r.Impact()) })
}
