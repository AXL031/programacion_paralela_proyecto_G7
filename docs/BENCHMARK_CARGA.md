# Benchmark de carga local L1/L4

Estado: campaña de carga `g7-carga-l1l4b` ejecutada y validada (12/12 muestras correctas). Los adaptadores de entrenamiento, API y resumen siguen sin integrarse, por lo que la acción `Run` completa y la revisión de Cueva permanecen pendientes. Las cifras de este documento provienen únicamente de las muestras y de la evidencia exportada de esa campaña.

El contrato de orquestación, aislamiento y evidencia es [CONTRATO_BENCHMARK.md](CONTRATO_BENCHMARK.md). El plan general de las semanas 11–13 está en [PLAN_SEMANAS_11_13.md](PLAN_SEMANAS_11_13.md).

## 1. Objetivo y alcance

Demostrar si el loader local cambia su tiempo o su capacidad de ingesta cuando procesa con una o cuatro goroutines, manteniendo exactamente los mismos datos, lotes, filtro, almacenamiento y presupuesto de CPU.

La comparación es **L1 frente a L4**:

- **L1:** `loader -workers 1`.
- **L4:** `loader -workers 4`.

Ambos casos ejecutan el mismo binario y el mismo pipeline. `-workers` solo cambia el número de goroutines de procesamiento; no crea otro algoritmo, no cambia el formato, no divide la carga entre máquinas y no aumenta el presupuesto de CPU del contenedor.

Fuera de alcance:

- Presentar la ingesta como multinodo o distribuida.
- Cambiar el dataset, el período, los splits, las ventanas, los lotes, el seed o la configuración de entrenamiento para mejorar la comparación.
- Usar la base, el dataset o el modelo de la demo.
- Sustituir fallos por ceros, promedios históricos o muestras de otra campaña.
- Declarar una mejora estadística universal con cinco repeticiones.

## 2. Diseño experimental

### 2.1 Casos

| Caso | Workers de procesamiento | Proceso | `GOMAXPROCS` | Cuota de CPU | MongoDB |
|---|---:|---|---:|---:|---|
| L1 | 1 | Loader local | 4 | 4.0 | Base exclusiva y vacía por ensayo |
| L4 | 4 | Loader local | 4 | 4.0 | Base exclusiva y vacía por ensayo |

`GOMAXPROCS=4` y la cuota de CPU se mantienen iguales en L1 y L4. El contenedor del loader conserva además `mem_limit=1536m`. Por tanto, la comparación mide el efecto de las goroutines de procesamiento dentro de un solo proceso, no el efecto de asignar más núcleos o más contenedores.

### 2.2 Datos congelados

La configuración de referencia es `configs/demo.json`:

| Elemento | Valor |
|---|---|
| Fuente | NYC TLC Yellow Taxi, enero de 2024 |
| Archivo | `data/raw/yellow_tripdata_2024-01.parquet` |
| Catálogo | `data/raw/taxi_zone_lookup.csv` |
| Período | `2024-01-01T00:00:00-05:00` a `2024-01-16T00:00:00-05:00`, fin exclusivo |
| Zona horaria | `America/New_York` |
| Ventana | 15 minutos |
| `block_rows` | 4096 |
| `batch_rows` | 1000 |
| Almacenamiento | MongoDB, base `g7_benchmark` del proyecto aislado |
| Versión de procesamiento | `yellow-clean-v1` |

El dataset congelado documenta este resultado esperado, que la campaña debe verificar y no asumir:

| Elemento | Valor esperado |
|---|---:|
| Slots de 15 minutos | 1,440 (15 días × 96) |
| Zonas del catálogo | 263 |
| Ventanas | 378,720 |
| Ejemplos del snapshot | 378,457 |
| Split train | 264,841 |
| Split validation | 56,808 |
| Split test | 56,808 |
| Viajes válidos aceptados | más de 1,000,000; la referencia histórica documenta 1,348,665 |

Los rechazos y las filas fuera del período no se fijan aquí: se leen del manifiesto y se comparan entre L1 y L4 por causa. El SHA-256 del snapshot tampoco se hardcodea; se calcula sobre el archivo y se contrasta con el manifiesto y con la referencia de la campaña.

### 2.3 Identidad y base por ensayo

- `dataset_id` es determinista y depende de la fuente, el catálogo, el período, la zona horaria, la ventana, el formato y la versión de procesamiento. L1 y L4 deben producir el mismo `dataset_id`.
- `load_id` identifica una carga nueva y puede cambiar entre ensayos equivalentes.
- Cada muestra usa una base MongoDB vacía. El adaptador solo elimina `g7_benchmark` después de validar proyecto, etiquetas, montajes y argumentos de Compose. Nunca toca la base de la demo.
- El loader se ejecuta con `-require-fresh`. Si encuentra un dataset completo, devuelve `ErrReuseRejected` en lugar de reutilizar el manifiesto y sus estadísticas históricas.
- Una muestra con `reused=true` no es válida.

## 3. Protocolo y orden

La configuración `configs/benchmark.json` fija:

- `warmups=1`
- `repetitions=5`
- `loader_workers=[1, 4]`
- `timeout_seconds=1800`
- `seed=42`

Para carga se planifican **12 muestras**: 2 calentamientos y 10 mediciones.

| Fase | Orden |
|---|---|
| Calentamiento | `L1-w1`, `L4-w1` |
| Medición | `L4-r1`, `L1-r1`, `L1-r2`, `L4-r2`, `L4-r3`, `L1-r3`, `L1-r4`, `L4-r4`, `L4-r5`, `L1-r5` |

El orden se rota por ronda con el `seed` registrado; el plan exacto queda en `plan.json`. Los calentamientos se validan y se conservan, pero se excluyen de los resúmenes. Las muestras de carga se ejecutan antes de entrenamiento y API, y nunca en paralelo con otro caso de rendimiento.

Reglas de conservación:

- No repetir selectivamente hasta obtener un tiempo favorable.
- Conservar muestras fallidas y su causa.
- Si se corrige una condición que invalida la campaña, iniciar una campaña nueva.
- No mezclar campañas con protocolos distintos.

## 4. Comandos

### 4.1 Preparación y campaña

Ejecutar desde la raíz del repositorio, con PowerShell 7.2 o posterior, Git y Docker Desktop con motor Linux. No se requiere Go instalado en Windows.

```powershell
./scripts/benchmark.ps1 -Action Plan -Campaign g7-carga-l1l4b
./scripts/benchmark.ps1 -Action Prepare -Campaign g7-carga-l1l4b
./scripts/benchmark.ps1 -Action Run -Campaign g7-carga-l1l4b
./scripts/benchmark.ps1 -Action Stop -Campaign g7-carga-l1l4b
./scripts/benchmark.ps1 -Action Export -Campaign g7-carga-l1l4b
```

- `Plan` no requiere Docker. Congela configuración, fuentes y plan, y muestra los adaptadores que faltan.
- `Prepare` construye imágenes y levanta MongoDB, Redis, maestro, workers y API con límites explícitos.
- `Run` exige que los cinco adaptadores estén integrados. El adaptador de carga y el colector de recursos ya existen, pero la campaña completa sigue bloqueada mientras falten los adaptadores de entrenamiento, API y resumen (#3/#4/#5). La campaña `g7-carga-l1l4b` se ejecutó invocando `scripts/benchmark-load.ps1` muestra por muestra sobre el contexto `Prepare`; no se usó `Run`.
- `Stop` retira únicamente los servicios y la red del proyecto validado; conserva volúmenes, datos y evidencia.
- `Export` genera un ZIP con la evidencia permitida y redacta los secretos conocidos.

No ejecutar Compose del benchmark a mano con proyectos, bases o variables inventadas. El adaptador usa `context.compose_arguments`; no define valores ocultos.

El adaptador de carga se invoca con la interfaz del contrato:

```powershell
param(
  [Parameter(Mandatory)][string]$ContextPath,
  [Parameter(Mandatory)][string]$SamplePath,
  [Parameter(Mandatory)][string]$OutputPath
)
```

Internamente ejecuta la forma equivalente a:

```text
docker compose <argumentos del contexto> --profile jobs run -T --rm --no-deps \
  loader -config data/configs/loader.json -workers N -require-fresh
```

No usar esa forma manualmente para una campaña real: el adaptador valida propiedad, etiquetas, montajes, configuración generada, checksums, base vacía y evidencia de recursos antes de ejecutarla.

### 4.2 Pruebas Go

Las pruebas que usan MongoDB se omiten si `MONGO_TEST_URI` no está definido. El servicio `dev` de Compose ya lo apunta al MongoDB del entorno:

```powershell
docker compose --profile tools run --rm dev go test -race -count=1 ./...
docker compose --profile tools run --rm dev go vet ./...
```

Para ejecutar solo los paquetes afectados por carga:

```powershell
docker compose --profile tools run --rm dev go test -race -count=1 ./internal/loader ./tests/integration
```

Pruebas de integración relevantes:

| Prueba | Qué comprueba |
|---|---|
| `TestMongoLoadAndReload` | Carga nueva, reutilización idempotente, conteos y publicación del dataset actual. |
| `TestMongoStrictReuseRejection` | `ErrReuseRejected` no devuelve métricas históricas y no modifica la carga publicada. |
| `TestMongoL1L4LogicalEquivalence` | L1/L4 con bases aisladas: identidad, conteos, rechazos, splits, snapshot, conteos MongoDB y equivalencia lógica. |

Cada prueba crea y elimina su propia base `transporte_test_<...>`; no usa `transporte` ni `g7_benchmark`.

Las pruebas unitarias de `internal/loader` cubren además `TestRejectReuse`, `TestTimingsConfigurationAndThroughput` y `TestL1L4LogicalEquivalence` con el fixture pequeño.

## 5. Semántica de fases y métricas

Los tiempos de fase son los del loader, no los del adaptador. El adaptador no suma preflight, reinicio de base, colector ni verificación a las fases.

| Fase | Desde | Hasta | Incluye | Excluye |
|---|---|---|---|---|
| `preparation_seconds` | Inicio de `RunWithOptions` | Fuente abierta | Validación de configuración, hashes de fuente/catálogo, lectura de zonas, período, identidad del dataset, `store.Begin` y creación de índices | Lectura/procesamiento de filas |
| `compute_seconds` | Fin de preparación | Después del re-hash de la fuente | Lectura, parseo, validación, inserción por lotes y re-hash posterior a la ingesta | Exportación del snapshot y `store.Complete` |
| `evaluation_seconds` | No aplica | No aplica | `null` para carga | Cualquier fase de evaluación |
| `publication_seconds` | Fin de `compute` | Después de `store.Complete` | Exportación de snapshot/ventanas y `store.Complete` | Verificación del adaptador |
| `total_seconds` | Inicio de `RunWithOptions` | Después de `store.Complete` | Suma de preparación, cómputo y publicación | Overhead del adaptador |

El adaptador exige que `preparation + compute + publication = total` con tolerancia `1e-9` y que `evaluation_seconds` sea `null`. El runner conserva `adapter_elapsed_seconds` en el manifiesto como dato operativo, pero no lo usa como tiempo de carga ni lo suma a las fases.

La evidencia de recursos cubre la ventana del proceso loader. No redefine ni completa las fases internas del loader.

Métricas de conteo:

- `read = accepted + rejected + outside_period`
- `persisted = accepted`
- La suma de `rejection_reasons` debe ser igual a `rejected`.
- `accepted` debe ser mayor que 1,000,000 en una campaña real.

Throughput:

- `rows_per_second = read / stats.elapsed_seconds`
- `accepted_per_second = accepted / stats.elapsed_seconds`

`stats.elapsed_seconds` es el temporizador heredado del manifiesto: abarca desde el inicio del loader hasta antes de `store.Complete`. No es igual a `timings.total_seconds`. El adaptador verifica ambas fórmulas contra los conteos y el valor declarado; no las recalcula con otro reloj.

La configuración devuelta por el loader debe coincidir con el caso: `workers`, `GOMAXPROCS=4`, `storage=mongo`, formato, ventana y `processing_version`. El manifiesto debe coincidir con la configuración congelada en nombre, fuente, período, zona horaria, formato y ventana.

## 6. Verificación independiente

El adaptador `scripts/benchmark-load.ps1` realiza estas comprobaciones antes de aceptar una muestra:

1. **Identidad de la muestra:** solo acepta `scope=real`; valida `schema_version`, campaña, `sample_id`, `case_id`, `kind=load`, repetición, calentamiento y `workers` en `{1,4}`. Rechaza sobrescribir una salida existente.
2. **Propiedad y Compose:** valida proyecto, etiquetas, montajes, credenciales privadas, argumentos de Compose y límites. Exige `GOMAXPROCS=4`.
3. **Configuración generada:** compara `data/bench/<campaña>/configs/loader.json` con `configs/demo.json`; comprueba que el almacenamiento sea MongoDB, la base sea la del contexto, la salida sea `data/processed` y las rutas sean relativas al repositorio.
4. **Checksums de entrada:** calcula SHA-256 de la fuente y del catálogo y los contrasta con sus archivos `.sha256`.
5. **Servicios:** exige MongoDB running/healthy y que no haya un loader o trainer activo en el proyecto.
6. **Colector de recursos:** exige que `config.components.resources` exista. Sin colector no se ejecuta una muestra real.
7. **Reinicio:** después de validar propiedad y etiquetas, elimina solo `g7_benchmark`; comprueba el nombre de la base y que no queden colecciones.
8. **Carga estricta:** ejecuta el loader con `-require-fresh`; un dataset completo se rechaza, no se reutiliza.
9. **Recursos:** inicia el colector antes del loader y lo detiene inmediatamente después. Valida cada línea NDJSON contra `schemas/benchmark-resource.schema.json`, comprueba que pertenezca a la muestra y exige al menos una observación disponible. Guarda ruta relativa, SHA-256 y conteos válidos/faltantes.
10. **Resultado del loader:** exige `reused=false`, IDs válidos, hashes de fuente/catálogo/snapshot, estado `complete`, conteos consistentes, rechazos por causa, throughput, fases, configuración e identidad del manifiesto.
11. **Snapshot:** comprueba versión, ventanas, ejemplos, splits, features, `train_end`, `validation_end`, normalización y que el archivo exista con bytes mayores que cero y SHA-256 igual al manifiesto. Calcula las ventanas/ejemplos/splits esperados a partir del período y las zonas.
12. **MongoDB independiente:** con `mongosh` sobre la base aislada verifica el manifiesto, el dataset actual, los viajes y ventanas del `load_id`, los totales de la base y la suma de `observed_trips` de las ventanas. Todos deben coincidir con el resultado del loader.
13. **Referencia de campaña:** la primera muestra completamente válida escribe `bench/raw/<campaña>/reference/snapshot.json`. Las siguientes comparan dataset, hashes, conteos, rechazos por causa, splits, features, período, versión de procesamiento y hash canónico de zonas. Una diferencia invalida la muestra.
14. **Esquema y runner:** construye la muestra, la valida contra `schemas/benchmark-result.schema.json` y solo entonces la escribe. El runner vuelve a validar identidad, estado, checks y recursos.

La equivalencia lógica no depende del orden físico de inserción:

- El adaptador compara conteos, agregados y la suma de ventanas; no compara el orden de los documentos.
- Las pruebas de integración normalizan `_id` y `load_id` y ordenan los viajes por `source_row` y las ventanas por `(start, zone_id)` antes de comparar.
- Un orden distinto de inserción es aceptable si los datos lógicos, conteos y checksums coinciden.

### 6.1 Fallos

- Un fallo del loader o del colector se conserva en `bench/raw/<campaña>/failures/<sample_id>.json`, con etapa, error, códigos y colas de salida redactadas.
- Un fallo de verificación posterior a una carga correcta produce una muestra JSON válida con `status=failed`, checks falsos y errores; no se convierte en ceros.
- Un fallo fatal antes de poder construir la muestra también deja un artefacto separado.
- Los contenedores del loader se eliminan solo después de un fallo o timeout del loader, nunca después de una muestra exitosa.
- El runner falla ante una muestra fallida aunque el proceso haya devuelto 0.

## 7. Evidencia

### 7.1 Estructura

```text
bench/results/<campaña>/
  reference.json          # commit, estado sucio, diff y hashes de fuentes congeladas
  config.json             # configs/benchmark.json congelado
  plan.json               # 12 muestras de carga + casos de entrenamiento/API
  manifest.json           # estado de la campaña y muestras ejecutadas
  environment.json        # CPU/RAM del motor, Docker/Compose, imágenes, inputs
  samples/
    L1-w1.json
    L4-w1.json
    L1-r1.json
    ...
    L4-r5.json
  summary.json            # agregado; no incluye calentamientos
  demo-before-run.json
  demo-after-run.json
  preservation-run.json

bench/raw/<campaña>/
  plans/<sample_id>.json
  reference/snapshot.json # referencia de equivalencia del adaptador
  resources/<sample_id>.ndjson
  logs/<sample_id>-loader.stdout.log
  logs/<sample_id>-loader.stderr.log
  logs/<sample_id>-resources.stdout.log
  logs/<sample_id>-resources.stderr.log
  logs/load-reset.*.log
  logs/load-verify.*.log
  failures/<sample_id>.json
```

`bench/results/` se versiona; `bench/raw/` y `data/` están ignorados por Git. `bench/raw/<campaña>/reference/snapshot.json` es la referencia de equivalencia del adaptador y no debe confundirse con `bench/results/<campaña>/reference.json`, que registra la congelación Git/fuentes de la campaña.

Los datos escribibles de la campaña viven en `data/bench/<campaña>/`, incluido el snapshot en `data/bench/<campaña>/processed/<dataset_id>/<load_id>/features.ndjson`. No se publican automáticamente. `Export` produce un ZIP en `.cache/benchmark/exports/` con JSON/NDJSON/CSV/logs permitidos y secretos conocidos redactados.

### 7.2 Resultados de la campaña `g7-carga-l1l4b`

Campaña ejecutada el 2026-11-05 sobre el entorno aislado del benchmark. Se corrieron las 12 muestras del plan (2 calentamientos y 10 mediciones) con `scripts/benchmark-load.ps1`. Las 12 terminaron con `status=passed`, todos los checks en `true` y equivalencia lógica L1/L4 en todas las muestras.

Artefactos de la campaña:

- Muestras JSON: `bench/results/g7-carga-l1l4b/samples/`
- Análisis agregado: `bench/results/g7-carga-l1l4b/load-analysis.json`
- ZIP de evidencia: `bench/evidence/g7-carga-l1l4b.zip`
- SHA-256 del ZIP: `93f121f3715b93ea07bb7e8082dd0230127eaded5323b01f565a3027b62740c0`
- Manifiesto de campaña: `bench/results/g7-carga-l1l4b/manifest.json`

No se generó `summary.json`: el adaptador de resumen (#4) todavía no está integrado. Los agregados de esta sección provienen de `load-analysis.json`, calculados con `scripts/benchmark/statistics.psm1` a partir de las 10 muestras medidas; los calentamientos se excluyen.

**Resumen por caso** (5 mediciones por caso)

| Caso | n medidas | Mediana total (s) | Mediana preparación (s) | Mediana cómputo (s) | Mediana publicación (s) | Mediana filas/s | Mediana válidos/s | CPU máx. cont. (%) | RAM máx. proc. (MiB) | Speedup vs L1 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| L1 | 5 | 28.937 | 0.543 | 20.608 | 7.696 | 102,544 | 46,649 | 152.95 | 87.42 | 1.00 |
| L4 | 5 | 26.413 | 0.468 | 18.372 | 7.573 | 112,359 | 51,114 | 128.44 | 107.11 | 1.0956x |

Dispersión del tiempo total: L1 media `28.885 s`, desviación estándar muestral `0.906 s`, mínimo `27.703 s`, máximo `29.935 s`; L4 media `26.615 s`, desviación `0.570 s`, mínimo `26.001 s`, máximo `27.469 s`. El speedup sobre medianas es `1.0956x` en total y `1.1217x` en cómputo.

La columna `CPU máx. cont.` es la mediana de los máximos por muestra reportados por el colector de recursos (`container_max_cpu_percent`). Los valores por encima de 100% son normales porque el porcentaje se mide contra un núcleo. `RAM máx. proc.` es la mediana de `process_max_memory_bytes` convertida a MiB.

**Detalle de muestras**

| Muestra | Calentamiento | Repetición | Estado | Total (s) | Cómputo (s) | Leídas | Aceptadas | Rechazadas | Fuera de período | Persistidas | Recursos válidos/faltantes |
|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| L1-w1 | Sí | 1 | passed | 27.984 | 20.261 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 102/6 |
| L4-w1 | Sí | 1 | passed | 26.267 | 18.105 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 102/6 |
| L1-r1 | No | 1 | passed | 29.549 | 20.608 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 114/6 |
| L4-r1 | No | 1 | passed | 26.001 | 18.059 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 101/7 |
| L1-r2 | No | 2 | passed | 28.303 | 20.304 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 95/13 |
| L4-r2 | No | 2 | passed | 26.413 | 18.372 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 102/6 |
| L1-r3 | No | 3 | passed | 29.935 | 20.993 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 107/13 |
| L4-r3 | No | 3 | passed | 27.469 | 19.443 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 95/13 |
| L1-r4 | No | 4 | passed | 27.703 | 19.891 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 95/13 |
| L4-r4 | No | 4 | passed | 26.868 | 18.717 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 102/6 |
| L1-r5 | No | 5 | passed | 28.937 | 20.787 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 95/13 |
| L4-r5 | No | 5 | passed | 26.322 | 18.207 | 2,964,624 | 1,348,665 | 14,905 | 1,601,054 | 1,348,665 | 102/6 |

**Equivalencia L1/L4**

| Verificación | Valor en las 12 muestras | Resultado |
|---|---|---|
| `reused` | `false` | Cumple |
| `dataset_id` | `ds-f16643c248cc24d26b992f45598dd3e8` | Cumple |
| SHA-256 snapshot | `d968869fbb389169a9671661a2e77b42f793bc0b5d44573353ef754b124e1e7b` | Cumple |
| Ventanas / ejemplos | 378,720 / 378,457 | Cumple |
| Splits train/validation/test | 264,841 / 56,808 / 56,808 | Cumple |
| Leídas / aceptadas / rechazadas / fuera / persistidas | 2,964,624 / 1,348,665 / 14,905 / 1,601,054 / 1,348,665 | Cumple |
| Rechazos por causa | `duration_over_24h=8`, `nonpositive_duration=43`, `unknown_zone=14,854` | Cumple |
| Viajes y ventanas en MongoDB | 1,348,665 / 378,720 | Cumple |
| Suma de `observed_trips` | 1,348,665 | Cumple |

La campaña anterior `g7-carga-l1l4` se conserva en el entorno local como evidencia del fallo de compatibilidad con PowerShell 7.6 (el parseo automático de fechas desplazaba el período del manifiesto); no forma parte de la evidencia versionada. Su muestra `L1-w1` no se usa en ningún agregado.

## 8. Límites de interpretación

- **Es un benchmark local.** L4 usa cuatro goroutines de procesamiento dentro de un proceso, no cuatro nodos. No demuestra escalamiento entre servidores ni ingesta distribuida.
- **El presupuesto de CPU es el mismo.** `GOMAXPROCS=4` y `cpus=4.0` se mantienen en ambos casos. L1 no se ejecuta con un núcleo ni con menos CPU que L4.
- **La caché de disco no es fría.** El calentamiento reduce el efecto de la primera lectura, pero no se vacía la caché del sistema operativo ni se declara una medición de disco completamente fría. La evidencia registra rutas, tamaños y SHA-256 de las entradas.
- **MongoDB comparte el host.** Los tiempos incluyen la latencia real del MongoDB aislado y la creación de índices de la base vacía en preparación. No representan un almacenamiento remoto ni un clúster.
- **Cinco repeticiones son exploratorias.** Informar dispersión y no prometer una mejora universal. Un valor menor que 1 en el speedup significa que L4 fue más lento.
- **La captura de recursos ya está integrada.** `scripts/benchmark-resources.ps1` produce la evidencia por muestra y el adaptador exige al menos una observación disponible; la cobertura (`valid_samples`/`missing_samples`) queda registrada en cada muestra.
- **El resumen depende de #4.** El adaptador de resumen no está integrado, así que no existe `summary.json`. Los agregados de la sección 7.2 se calcularon con `scripts/benchmark/statistics.psm1` sobre las muestras medidas y quedan en `load-analysis.json`.
- **La comparación no cambia la demo.** Antes/después de `Run` se registran hashes de archivos y, si está disponible, el estado de MongoDB de la demo. Un cambio hace fallar la operación.
- **No se modifican datos ni hiperparámetros para obtener una mejora.** Si aparece un cuello de botella, se propone un cambio acotado y se repite la comparación afectada con datos y configuración idénticos.

## 9. Criterios de cierre del issue #2

| Criterio | Estado |
|---|---|
| L1/L4 con datos equivalentes y `reused=false` en todas las mediciones | Cumplido en carga: 12/12 muestras con `reused=false` y equivalencia lógica |
| Dataset real con más de un millón de viajes válidos, conteos/splits/checksum verificados | Cumplido: 1,348,665 aceptados; conteos, splits y SHA-256 verificados |
| Calentamientos identificados y cinco muestras medidas por caso, fallos preservados | Cumplido en carga: `L1-w1`/`L4-w1` y 5 mediciones por caso; el fallo previo se conserva en `g7-carga-l1l4` |
| Tiempos, throughput, configuración, recursos/cobertura y orden vinculados a campaña | Cumplido en carga: fases, throughput, recursos y orden registrados por muestra |
| Pruebas existentes y afectadas, incluida integración MongoDB | Parcial: el adaptador verificó MongoDB en cada muestra; las pruebas Go siguen pendientes en el host final |
| Evidencia accesible, interpretación local y límites documentados | Cumplido: `bench/results/g7-carga-l1l4b/` y `bench/evidence/g7-carga-l1l4b.zip` |
| PR de `lopez` a `main`, revisión de Cueva y correcciones resueltas | Pendiente; sin auto-merge |

## 10. Referencias

- [Contrato benchmark-v1](CONTRATO_BENCHMARK.md)
- [Esquema de muestra](../schemas/benchmark-result.schema.json)
- [Esquema de recursos](../schemas/benchmark-resource.schema.json)
- [Plan de semanas 11–13](PLAN_SEMANAS_11_13.md)
- [Distribución de tareas](DISTRIBUCION_SEMANAS_11_13.md)
- [Configuración del benchmark](../configs/benchmark.json)
- [Configuración de datos congelada](../configs/demo.json)
- [Adaptador de carga](../scripts/benchmark-load.ps1)
- [Evidencia de la campaña de carga](../bench/evidence/g7-carga-l1l4b.zip)
