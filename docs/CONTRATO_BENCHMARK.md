# Contrato benchmark-v1

Primera entrega de Cueva para el issue #1. Define interfaces que consumirán #2, #3, #4 y #5. La integración real y las campañas siguen pendientes; este contrato no certifica resultados de rendimiento.

## Inicio y aislamiento

Requisitos: PowerShell 7.2 o posterior, Git, Docker Desktop con motor Linux y los originales de `configs/demo.json` descargados con el procedimiento existente. No se requiere Go en Windows. Ejecutar desde el repositorio:

```powershell
./scripts/benchmark.ps1 -Action Plan -Campaign g7-campana-01
./scripts/benchmark.ps1 -Action Prepare -Campaign g7-campana-01
# Run solo cuando los cinco adaptadores estén integrados.
./scripts/benchmark.ps1 -Action Run -Campaign g7-campana-01
./scripts/benchmark.ps1 -Action Stop -Campaign g7-campana-01
./scripts/benchmark.ps1 -Action Export -Campaign g7-campana-01
```

`Plan` no requiere Docker: congela configuración/referencia, enumera casos y muestra adaptadores ausentes. `Prepare` construye imágenes antes de medir e inicia servicios con límites explícitos. `Run` falla si falta un adaptador, la campaña ya se ejecutó, cambió una fuente congelada o un resultado no satisface el contrato. Cada campaña admite un intento de ejecución: corregir y usar un identificador nuevo para conservar los fallos.

`Smoke` prepara infraestructura y prueba los binarios actuales con el fixture pequeño, ambos modos de entrenamiento, tareas de workers, MongoDB y predicciones con miss/hit Redis:

```powershell
./scripts/benchmark.ps1 -Action Smoke -Campaign g7-infra-smoke-01
./scripts/benchmark.ps1 -Action Stop -Campaign g7-infra-smoke-01
```

Su alcance se guarda como `infrastructure_smoke_synthetic_data`: no verifica candidatos SGD previos a selección, no mide recursos formalmente y no sustituye los adaptadores ni una campaña real. Usar otra campaña para medir datos reales; no reutilizar la base del smoke.

El archivo Compose es **independiente**, nunca un override de `docker-compose.yml`. El runner usa argumentos explícitos, sin shell intermedio, `--project-directory`, `--env-file`, `-p` y `-f`. No ejecutar Compose de benchmarks a mano con variables inventadas.

| Recurso | Ubicación o nombre |
|---|---|
| Proyecto | `transporte-g7-bench-<campaña>` |
| Base MongoDB | `g7_benchmark`, dentro del MongoDB exclusivo del proyecto |
| API | `127.0.0.1:18080` por defecto; sin web de benchmark |
| Datos/modelos escribibles | `data/bench/<campaña>/`, montado como `/app/data` |
| Originales | `data/raw`, bind de solo lectura dentro de `/app/data/raw` |
| Workers | Directorio de campaña de solo lectura |
| Credenciales/contexto privado | `.cache/benchmark/<campaña>/` (ignorado por Git) |
| Configuración generada | `/app/data/configs/loader.json`, `/app/data/configs/training.json` |

Los servicios/volúmenes/redes llevan etiquetas `g7.benchmark.managed=benchmark-v1` y `g7.benchmark.campaign=<campaña>`. Se validan nombres, etiquetas y montajes antes de operar. Se rechazan rutas fuera del repositorio y junctions/symlinks. Un mutex de host impide solapar operaciones del runner entre copias de este proyecto que usen el mismo usuario/sesión de Windows. No coordina otras máquinas, otros usuarios ni comandos Docker manuales; Cueva organiza los turnos.

`Stop` retira únicamente servicios/red del proyecto validado. **Conserva volúmenes, datos, modelos, credenciales y evidencia.** No hay acción de borrado de volúmenes/directorios en esta entrega; su retención es manual y explícita después de archivar la campaña. No usar `docker system prune` para limpiarla.

## Plan de casos

La configuración principal está en `configs/benchmark.json`. Cada ejecución real mantiene sus entradas, componentes y protocolo acordado. Para modificar el protocolo, acordar y versionar una nueva definición; no editar un experimento a mitad de ejecución.

- Carga: L1/L4, un calentamiento y cinco mediciones por caso.
- Entrenamiento: S/D1/D2/D4, un calentamiento y cinco mediciones por caso.
- API: caché cold/warm/unavailable, concurrencia 1/10/25, tres pasadas de 1,000 peticiones medidas por combinación. Login/precalentamiento quedan fuera.
- Total: 63 ejecuciones de muestra, de las cuales seis son calentamientos. Son 27,000 solicitudes API medidas.
- Orden determinista rotado por ronda usando `seed`; carga antecede entrenamiento y entrenamiento antecede API. No se ejecutan muestras en paralelo.

La configuración de prueba `tests/benchmark/fixtures/config.json` solo admite adaptadores debajo de `tests/benchmark/fixtures/` y produce `scope=orchestrator_fixture`. No puede pasar como campaña real ni evaluar objetivos.

## Interfaces de componentes

Los responsables publican adaptadores PowerShell 7.2, sin cambiar sus motores para acomodar la orquestación:

| Clave | Archivo | Responsable |
|---|---|---|
| load | `scripts/benchmark-load.ps1` | López #2 |
| training | `scripts/benchmark-training.ps1` | Gerardo #4, consume diagnósticos de Taco #3 |
| api | `scripts/benchmark-api.ps1` | Dragon #5 |
| resources | `scripts/benchmark-resources.ps1` | Gerardo #4 |
| summary | `scripts/benchmark-summary.ps1` | Gerardo #4; acordar su utilidad Go interna si aplica |

Los adaptadores `load`, `training` y `api` reciben exactamente:

```powershell
param(
  [Parameter(Mandatory)][string]$ContextPath,
  [Parameter(Mandatory)][string]$SamplePath,
  [Parameter(Mandatory)][string]$OutputPath
)
```

El runner ejecuta un proceso hijo con timeout y conserva stdout/stderr redactados en `bench/raw/<campaña>/logs/`. El adaptador escribe **una muestra** JSON en `OutputPath` y devuelve 0 si el procedimiento terminó correctamente. Un resultado con `status=failed`, checks falsos o JSON ausente/inválido falla aunque el proceso devuelva 0. Los errores y muestras parciales se conservan; no sustituirlos por ceros.

El contexto privado contiene `campaign_id`, `scope`, `project`, `database`, `repo_root`, `config`, `results_dir`, `raw_dir`, `data_dir`, `api_url`, `compose_arguments`, `env_file` y `result_schema`. Usar `compose_arguments` para toda llamada Docker del benchmark; los scripts no definen proyectos/bases ocultos. Nunca copiar el contexto completo ni `env_file` a evidencia pública.

La muestra de entrada tiene `schema_version`, `campaign_id`, `sample_id`, `case_id`, `kind`, `repetition`, `warmup` y `parameters`. En carga: workers; en entrenamiento: workers y mode; en API: cache, concurrency y requests.

### Responsabilidades internas por muestra

- López crea una base vacía dentro del MongoDB aislado para cada carga: puede vaciar la base fija solo tras validar proyecto/etiquetas. Rechaza `reused=true`, verifica conteos/snapshot y deja un dataset válido al terminar. No cambia la base por una de la demo.
- Gerardo escala únicamente los workers del proyecto exclusivo antes de cada caso y verifica cantidad/contribución. Para S, registra que el trainer ejecuta el cómputo local; para Dn, consume el diagnóstico previo a selección de Taco. D1 permite cuantificar sobrecoste TCP.
- Dragon obtiene dataset/modelo actuales de ese entorno, valida consultas, prepara Redis según escenario y lo restaura en `finally`. No mezcla directo/proxy; la comprobación por proxy se documenta aparte.
- Los tres adaptadores invocan el colector de recursos de Gerardo durante su fase medida. El runner no inicia otro colector en paralelo ni mide el tiempo total de un proceso adaptador como núcleo de entrenamiento.

Interfaz propuesta del colector a implementar por Gerardo:

```powershell
param(
  [Parameter(Mandatory)][string]$ContextPath,
  [Parameter(Mandatory)][string]$SamplePath,
  [Parameter(Mandatory)][string]$OutputPath,
  [Parameter(Mandatory)][string]$StopFile
)
```

Se inicia como proceso hijo antes del trabajo, escribe NDJSON y termina al aparecer `StopFile`. Los adaptadores conservan su PID, crean la señal en `finally`, esperan su salida y evitan procesos colectores huérfanos si falla la muestra. `OutputPath` y `StopFile` se restringen al `raw_dir`. No simular datos cuando el muestreo falla. Esta interfaz es un contrato entregado, **no un colector ya implementado**.

El agregador recibe `ContextPath`, `ManifestPath`, `OutputPath`. Debe devolver JSON con `schema_version`, `campaign_id`, `scope`, `status=passed`, `sample_ids` (todos los IDs, incluidos calentamientos identificados), tablas y limitaciones. Sus tablas excluyen calentamientos y distinguen campañas incompatibles. El runner comprueba cobertura/identidad; las fórmulas y la auditoría independiente corresponden a Gerardo/Vera.

## Salida de muestra y comprobaciones

Esquema obligatorio: [`benchmark-result.schema.json`](../schemas/benchmark-result.schema.json). Una muestra conserva:

- Identidad, UTC, scope, kind, repetition, warmup, status y errores.
- Dataset/load ID y SHA-256 de snapshot/fuente/catálogo. Dataset y hashes se mantienen entre casos; el load ID puede cambiar en una nueva ingesta equivalente.
- Fases en segundos: preparation, compute, evaluation, publication y total. `null` significa no instrumentado/no aplicable y debe explicarse en la documentación del componente; nunca inventar un cero. Total estrictamente positivo.
- `resources`: available/unavailable/synthetic, ruta relativa al repositorio, SHA-256, conteos de observaciones válidas y faltantes.
- Checks de dataset, resultado y recursos, más checks específicos. Una muestra real sin recursos verificables no pasa.
- Métricas específicas detalladas en el esquema; los valores tienen tipos numéricos reales, no texto formateado.

En carga se exige `snapshot_equivalent=true`, contabilidad leída=aceptada+rechazada+fuera de período, persistida=aceptada y más de un millón de viajes aceptados para scope real.

En entrenamiento se exige `candidate_equivalent=true`, workers únicos y tareas positivas por cada worker requerido. Para S, la lista/mapa de workers está vacía. El diagnóstico de candidato es un JSON bajo `bench/raw/<campaña>/` con `sample_id`, `reference_weights` y `candidate_weights`, más metadatos de encoder/snapshot/semilla/splits documentados por Taco. `metrics.candidate_diagnostics_path` y `metrics.candidate_diagnostics_sha256` lo identifican; el runner verifica hash, dimensiones, valores finitos y cada parámetro antes de selección:

`abs(a-b) <= absolute_tolerance + relative_tolerance * max(abs(a),abs(b))`.

`candidate_max_difference` debe corresponder al diagnóstico, separado de la equivalencia del modelo publicado. Taco definirá la referencia secuencial efectiva y su compatibilidad de encoder/datos: el runner no puede probar eso a partir de dos vectores aislados.

En API se exige cantidad esperada de intentos/respuestas y cero errores inesperados para pasar; los errores no desaparecen de las salidas de intentos. La caché observada debe corresponder al escenario. Percentiles ordenados y coherencia de `objective_met` con **p95 <100 ms**. Una muestra correcta puede no lograr la meta de latencia: se reporta el incumplimiento, sin falsificar percentiles ni marcarlo como error del runner.

## Recursos

Cada línea cumple [`benchmark-resource.schema.json`](../schemas/benchmark-resource.schema.json): UTC, sample ID, servicio, scope process/container, available, cpu_percent y memory_bytes. En process, memoria significa RSS y 100% CPU equivale a un núcleo; en container se conserva la semántica Docker por separado. Ausencia usa `null` y `available=false`. El runner verifica cada línea y su cobertura declarada.

Gerardo calcula el máximo conjunto sumando observaciones alineadas, sin sumar máximos de instantes distintos. Conservar intervalo real, muestras antiguas/ausentes y fases de duración inferior al muestreo. La validación final revisa cobertura temporal y coherencia de métricas además del esquema.

## Evidencia, retención y conservación de demo

`bench/results/<campaña>/` conserva referencia, hashes de fuentes/configuración, plan exacto, estado, muestras, resumen, entorno y smoke/preservación. No confundir `planned`, `prepared`, `blocked`, `running`, `failed`, `fixture_passed`, `smoke_passed` y `completed`.

Fuentes versionadas y no rastreadas de las áreas de implementación se inventarían con SHA-256; también se registra commit, estado sucio y hash del diff. README y documentos ajenos al código no bloquean una campaña. Si cambia una fuente, iniciar otra campaña; no reescribir la referencia anterior. Builds, startup, login y precalentamientos no se suman silenciosamente al núcleo medido.

`bench/raw/` y `data/` están ignorados. `Export` crea un ZIP en `.cache/benchmark/exports/` con JSON/NDJSON/CSV/logs permitidos de resultados y bruto, redactando los secretos conocidos; excluye credenciales, contexto privado, datos/modelos grandes. No publica nada automáticamente. Adjuntar el ZIP al PR o a una ubicación acordada accesible al grupo, con SHA-256. Inspeccionar su contenido antes de compartir: la redacción no reconoce secretos arbitrarios añadidos por un adaptador.

Antes/después de Prepare/Smoke/Run/Stop se registran hashes de originales/modelos/snapshots de la demo y, si su MongoDB está disponible, punteros de dataset/modelo y conteos independientes. El resultado `mongo_observed=false` significa que solo se comprobó la parte de archivos. Cambios detectados hacen fallar la operación; podrían ser de otro usuario que usa la demo, y requieren investigación. No se certifica preservación de MongoDB cuando no pudo observarse.

Este mecanismo no sustituye la regresión final de JWT/WebSocket/navegador de Vera. La presencia de otras cargas se registra en el entorno y obliga a coordinar el aislamiento de rendimiento antes de ejecutar campañas reales. El smoke de infraestructura puede convivir con la demo, sin demostrar por ello condiciones de benchmark controladas.

## Qué falta para cerrar #1

- Integrar adaptadores reales de carga (#2), entrenamiento/recursos/agregación (#4), API (#5) y diagnósticos del candidato (#3).
- Acordar interfaces efectivas con cada responsable y probarlas sobre el contrato publicado.
- Ejecutar un smoke integrado de esos componentes y comprobar sus errores/recursos.
- Completar campañas reales, compartir evidencia bruta y corregir lo que demuestren.
- Obtener revisión independiente del PR. El issue #1 permanece abierto en esta entrega.
