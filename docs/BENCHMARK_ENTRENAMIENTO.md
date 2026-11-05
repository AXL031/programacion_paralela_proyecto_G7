# Instrumentación del entrenamiento y candidatos SGD previos a selección

Documento de la entrega de **Taco** para el issue [#3](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/3). Complementa el contrato [`CONTRATO_BENCHMARK.md`](CONTRATO_BENCHMARK.md) de Cueva y no declara campañas reales ni resultados de rendimiento nuevos.

## 1. Objetivo y alcance

- Que `trainer -mode sequential` y el entrenamiento TCP (`master` + workers) usen el mismo núcleo SGD, snapshot, encoder, splits, semilla e hiperparámetros.
- Registrar fases comparables: preparación, núcleo SGD, evaluación/selección, publicación y total.
- Conservar los pesos y diagnósticos del **candidato antes de `ml.Select`**, separados del modelo publicado.
- Comparar candidatos S/D1/D2/D4 con la tolerancia acordada y dejar evidencia estructurada para el adaptador de Gerardo (#4).

Los diagnósticos son opcionales. Sin los flags nuevos, el entrenamiento y los artefactos se comportan como antes.

## 2. Semántica de las fases

Los tiempos se miden con reloj monótono dentro del proceso correspondiente y se expresan en segundos.

| Fase | Campo | Incluye | No incluye |
|---|---|---|---|
| Preparación | `preparation_seconds` | Carga y verificación del snapshot, `ml.Fit`, `ml.Prepare`. En distribuido: envío de `prepare`, carga del snapshot y `Prepare` en cada worker, y espera de todas las confirmaciones `ready`. | Arranque de contenedores, conexión a MongoDB, espera de workers antes del run, compilación. |
| Núcleo SGD | `training_seconds` | `ml.Train`: barrido de épocas, mezcla con semilla, despacho de tareas por worker, cómputo del gradiente, agregación, regularización y actualización. En secuencial, `ml.Compute` local. | Carga del snapshot, evaluación, publicación. |
| Evaluación/selección | `evaluation_seconds` | `ml.Select` sobre validación (candidato, baseline y blends) y `ml.Evaluate` sobre train/validation/test. | Publicación. |
| Publicación | `publication_seconds` | `repo.Publish`: escritura del artefacto JSON, inserción en MongoDB y actualización del puntero `current_model`. | Persistencia final del registro del run. |
| Total | `total_seconds` | Reloj de pared desde justo antes de `training.Execute` hasta después del intento de publicación. | Arranque del proceso, conexión a MongoDB, espera de workers, persistencia final del run. |

En secuencial el total se mide desde antes de `Execute`; en distribuido desde antes de `Execute` dentro de `master.execute`, por lo que incluye el trabajo de coordinación del run (envío de `prepare`, espera de workers, agregación y parada). En ambos casos excluye la consulta previa del dataset actual en MongoDB. El `total_seconds` del maestro no incluye la espera del cliente HTTP ni el arranque del contenedor del trainer.

**Importante:** el adaptador mide además el tiempo total observado del proceso o contenedor. Ese valor no sustituye a `training_seconds` y no debe presentarse como núcleo SGD.

Si una fase no se alcanza (por ejemplo, fallo antes de publicar), su valor queda en `0`. Eso no significa "0 segundos medidos": el adaptador debe tratar el run como fallido y no agregarlo.

## 3. Candidato antes de `ml.Select`

`training.Execute` conserva:

- pesos del candidato entrenado;
- métricas de validación del candidato calculadas por `ml.Select` **antes** de elegir;
- método y blend de selección;
- `loss_history`, conteos de train/validation/test, dimensión, pasos y contribución por worker;
- encoder, snapshot, dataset, semilla y configuración.

El artefacto publicado (`Artifact`) no cambia de esquema y sigue conteniendo solo el modelo seleccionado por validación. Los pesos del candidato no se añaden a la API pública ni a MongoDB.

## 4. Formato `candidate-diagnostics-v1`

El trainer escribe un JSON con los campos mínimos que exige el runner de Cueva:

| Campo | Significado |
|---|---|
| `schema_version` | `candidate-diagnostics-v1`. |
| `sample_id` | Identificador de la muestra del plan (`^[a-zA-Z0-9-]+$`). |
| `run_id`, `mode` | Run real y modo `sequential` o `distributed`. |
| `dataset_id`, `snapshot_sha256` | Identidad de datos congelados. |
| `encoder_version`, `encoder_sha256` | Hash canónico del encoder (vocabulario y normalizadores). |
| `seed`, `config` | Semilla e hiperparámetros efectivos. |
| `train_examples`, `validation_examples`, `test_examples` | Conteos de splits. |
| `dimension`, `total_steps` | Dimensión del modelo y pasos del run. |
| `workers`, `tasks_by_worker` | Contribución real; vacío en S. |
| `reference_run_id`, `reference_mode` | Run secuencial de referencia. |
| `reference_weights`, `candidate_weights` | Vectores comparados antes de selección. |
| `reference_validation`, `candidate_validation` | Métricas de validación de ambos. |
| `candidate_max_difference` | Máximo `abs(a-b)` por parámetro. |
| `absolute_tolerance`, `relative_tolerance` | Tolerancias aplicadas. |
| `equivalent` | Resultado de aplicar la tolerancia a todos los parámetros. |
| `selection` | Método/blend y métricas del modelo seleccionado. |
| `loss_history` | Pérdida por época del candidato. |
| `published_weights_sha256` | Hash del modelo publicado, para no confundirlo con el candidato. |
| `created_at` | UTC. |

La comparación es por parámetro:

```text
abs(a-b) <= absolute_tolerance + relative_tolerance * max(abs(a), abs(b))
```

No se comparan hashes de floats: dos vectores con diferencias dentro de tolerancia no tienen por qué ser bit a bit iguales. Los valores iniciales acordados son `1e-9` absoluto y `1e-9` relativo.

`equivalent=false` se escribe igualmente como evidencia y el trainer termina con error visible. El runner de Cueva rechaza la muestra; no se oculta la divergencia.

## 5. Uso en el trainer

### Referencia secuencial S

```powershell
docker compose --profile jobs run --rm trainer `
  -mode sequential -config configs/training.json `
  -diagnostics data/training-sequential-diagnostics.json `
  -sample-id S
```

El diagnóstico de S se marca como referencia de sí mismo (`candidate_max_difference=0`, `equivalent=true`).

### Candidato distribuido D1/D2/D4

```powershell
docker compose --profile jobs run --rm trainer `
  -mode distributed -config configs/training.json `
  -diagnostics data/training-distributed-diagnostics.json `
  -sample-id D2 `
  -reference-diagnostics data/training-sequential-diagnostics.json
```

El trainer distribuido obtiene el candidato real del maestro mediante `GET /runs/{id}/candidate` (token interno). Si el maestro se reinicia antes de leerlo, el endpoint devuelve `404` y el trainer falla: no se inventan pesos.

Flags opcionales:

- `-tolerance-abs` y `-tolerance-rel` (por defecto `1e-9`).
- `-reference-diagnostics` solo es válido con `-mode distributed`.
- `-sample-id` es obligatorio cuando se usa `-diagnostics`.

La salida estándar mantiene `run` y `artifact`; añade `diagnostics` solo cuando se solicita:

```json
{
  "run": { "...": "..." },
  "artifact": { "...": "..." },
  "diagnostics": {
    "path": "data/training-distributed-diagnostics.json",
    "sha256": "<64 hex>",
    "sample_id": "D2",
    "candidate_max_difference": 2.3e-15,
    "absolute_tolerance": 1e-9,
    "relative_tolerance": 1e-9,
    "equivalent": true,
    "reference_run_id": "run-..."
  }
}
```

## 6. Interfaz para el adaptador de entrenamiento (#4, Gerardo)

El adaptador `scripts/benchmark-training.ps1` recibe `ContextPath`, `SamplePath` y `OutputPath`. Para cada muestra:

1. Ejecuta S una vez sobre el snapshot congelado y conserva su diagnóstico como referencia efectiva.
2. Para cada Dn, ejecuta el trainer con `-reference-diagnostics` apuntando al diagnóstico S.
3. Copia el JSON de diagnóstico a una ruta bajo `bench/raw/<campaña>/` (el runner exige ruta relativa al repositorio) y calcula su SHA-256.
4. Rellena en la muestra `benchmark-v1`:
   - `metrics.candidate_diagnostics_path`;
   - `metrics.candidate_diagnostics_sha256`;
   - `metrics.candidate_max_difference` (debe coincidir con el diagnóstico);
   - `metrics.workers` y `metrics.tasks_by_worker` (vacíos en S);
   - `metrics.model_version` (artefacto publicado);
   - `checks.candidate_equivalent=true`.
5. No usa el tiempo total del proceso como `compute_seconds`; usa `run.training_seconds` y conserva las demás fases.

El runner ya valida dimensiones, valores finitos, hash y tolerancia por parámetro. El adaptador no debe recalcular ni redondear la diferencia máxima.

## 7. Compatibilidad y fallos

- Los artefactos anteriores siguen validando: no se añadieron campos obligatorios a `Artifact` ni a su lectura.
- La selección sigue usando **solo validación**; test no participa.
- Un fallo de entrenamiento o de publicación conserva el modelo anterior (`current_model` no se actualiza).
- Un fallo de publicación deja `status=failed`, `artifact_version` vacío y conserva el candidato para diagnóstico.
- El diagnóstico de un run fallido no se escribe si no llegó a capturarse el candidato.
- Una divergencia de candidatos se detecta aunque S y Dn publiquen persistencia y sus pesos publicados sean idénticos.

## 8. Límites

- Entorno de una sola computadora; no demuestra escalamiento entre servidores.
- `GOMAXPROCS=1` por proceso y cuotas de contenedor explícitas; el número de workers cambia el presupuesto total.
- Cada worker mantiene una copia del snapshot; la RAM puede limitar D4.
- Un smoke con fixture sintético no es una campaña real ni sustituye las cinco repeticiones medidas.
- El endpoint de candidato vive en memoria del maestro; no es un almacén histórico.
- Los diagnósticos no prueban por sí solos que S y Dn usaron el mismo snapshot: el adaptador debe conservar dataset, hashes y configuración de la muestra.
