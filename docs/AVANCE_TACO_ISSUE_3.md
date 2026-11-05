# Avance de Taco: instrumentación SGD y candidatos previos a selección

Fecha: **5 de noviembre de 2026, Lima**. Rama: `taco`. Issue: [#3](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/3).

**Entrega parcial para revisión; el issue permanece abierto.** La implementación se apoya en el merge aprobado de `main` (`530fb5d`). La campaña repetida de Gerardo (#4) y la auditoría de Vera siguen pendientes, y el smoke real con el entorno aislado no se ejecutó en esta sesión. No se presentan fixtures como mediciones nuevas.

## Qué resuelve esta entrega

1. El trainer secuencial conserva los **pesos del candidato SGD antes de `ml.Select`**, además de su pérdida, métricas de validación, método/blend de selección y conteos de splits.
2. Los workers TCP usan el mismo `training.Execute`, el mismo snapshot, encoder, configuración y semilla. El maestro retiene el candidato real del run distribuido y lo expone por un endpoint interno autenticado.
3. Cada run registra fases comparables: `preparation_seconds`, `training_seconds`, `evaluation_seconds`, `publication_seconds` y `total_seconds`.
4. El trainer puede escribir un diagnóstico opcional `candidate-diagnostics-v1`, comparar S contra Dn con la tolerancia acordada por parámetro y fallar de forma visible si diverge.
5. El modelo publicado, la API pública y los artefactos existentes no cambian de esquema.

## Cambios principales

| Archivo | Cambio |
|---|---|
| `internal/training/run.go` | `Execute` devuelve el candidato; fases de publicación/total; `SequentialWithDiagnostics`. |
| `internal/training/diagnostics.go` | Esquema `candidate-diagnostics-v1`, validación, comparación por tolerancia y escritura atómica con checksum. |
| `internal/cluster/master/server.go` | Candidato en memoria por run, capturado antes de publicar; tiempos de publicación y total. |
| `internal/cluster/master/http.go` | `GET /runs/{id}/candidate`, protegido por el mismo token interno del maestro. |
| `cmd/trainer/main.go` | Flags `-diagnostics`, `-sample-id`, `-reference-diagnostics`, `-tolerance-abs`, `-tolerance-rel`; comparación y salida estructurada. |
| `scripts/train-demo.ps1` | Genera diagnósticos S/D y verifica candidatos además de los pesos publicados. |
| `docs/BENCHMARK_ENTRENAMIENTO.md` | Semántica de fases, formato, interfaz para el adaptador de #4 y límites. |

La comparación usa, por parámetro:

```text
abs(a-b) <= absolute_tolerance + relative_tolerance * max(abs(a), abs(b))
```

Valores iniciales: `1e-9` absoluto y `1e-9` relativo. `equivalent=false` se escribe como evidencia y el trainer termina con error; no se convierte en éxito.

## Cómo ejecutar

```powershell
# Referencia secuencial; el diagnóstico queda en el volumen ./data
docker compose --profile jobs run --rm trainer `
  -mode sequential -config configs/training.json `
  -diagnostics data/training-sequential-diagnostics.json -sample-id S

# Candidato distribuido contra la referencia S
docker compose --profile jobs run --rm trainer `
  -mode distributed -config configs/training.json `
  -diagnostics data/training-distributed-diagnostics.json `
  -sample-id D2 `
  -reference-diagnostics data/training-sequential-diagnostics.json
```

Sin `-diagnostics` la salida y el comportamiento son los anteriores. `-sample-id` es obligatorio con `-diagnostics`; `-reference-diagnostics` solo aplica a `distributed`.

El adaptador de #4 copia el JSON a `bench/raw/<campaña>/`, calcula su SHA-256 y rellena `candidate_diagnostics_path`, `candidate_diagnostics_sha256`, `candidate_max_difference`, `workers` y `tasks_by_worker` en la muestra `benchmark-v1`. El runner de Cueva ya valida hash, dimensiones, finitud, tolerancia y coincidencia de la diferencia máxima.

## Verificación ejecutada

Herramientas: Go portátil `go1.27.3 windows/amd64`, `gofmt`, `go vet`, `go test` y `go test -race` con `CGO_ENABLED=1` y GCC de MSYS2.

| Comando | Resultado |
|---|---|
| `gofmt -l cmd internal tests/integration` | Sin archivos pendientes. |
| `go vet ./...` | `EXIT=0`. |
| `go test -count=1 ./...` | `EXIT=0`; todas las pruebas pasan. |
| `go test -race -count=1 ./internal/training/... ./internal/cluster/master/... ./internal/ml/... ./tests/integration/...` | `EXIT=0`; sin carreras detectadas. |

Pruebas nuevas o ampliadas relevantes:

- **Candidato capturado antes de selección:** identidad, splits, dimensión, pérdida y validación del candidato coinciden con el run.
- **Persistencia no oculta divergencia:** dos candidatos distintos que publican los mismos pesos de persistencia se detectan como `equivalent=false`.
- **Fases:** preparación, cómputo y publicación se miden por separado y el total no es menor que su suma.
- **Fallo de publicación:** el run queda `failed`, conserva el candidato para diagnóstico y no reemplaza el modelo anterior.
- **Fuga temporal:** un split fuera de los límites declarados no publica ni deja candidato.
- **TCP 1/2/4:** los pesos publicados coinciden con la referencia y los candidatos previos a selección son equivalentes con la tolerancia acordada.
- **Endpoint de candidato:** exige token, devuelve `404` si el maestro no lo conserva y `200` con los pesos pre-selección.
- **Compatibilidad de diagnóstico:** snapshot, encoder, semilla, splits, configuración o dimensiones distintas se rechazan; la escritura es atómica y verificable.

## Pendiente y límites

- **Smoke real pendiente:** Docker Desktop no estaba iniciado y no hay dataset real en `data/raw`. Cuando se retome, se usará un fixture sintético identificado como tal, sin presentarlo como benchmark.
- **Campaña repetida:** la ejecuta Gerardo (#4) con el entorno aislado y las cinco repeticiones del protocolo.
- **Maestro en memoria:** el endpoint `/runs/{id}/candidate` no sobrevive a un reinicio del maestro. Si se reinicia, el trainer distribuido falla en vez de inventar pesos.
- **Alcance de tiempos:** `total_seconds` mide el run dentro del proceso (desde antes de `Execute` hasta después de publicar). No incluye arranque de contenedor, conexión a MongoDB ni la persistencia final del registro del run. El adaptador debe conservar además el tiempo total observado del contenedor, sin usarlo como núcleo SGD.
- **Entorno único:** no demuestra escalamiento entre servidores; `GOMAXPROCS=1` por proceso y cuotas explícitas.
- **Issue abierto:** no se usa `Closes #3` hasta completar smoke/campaña/auditoría.
