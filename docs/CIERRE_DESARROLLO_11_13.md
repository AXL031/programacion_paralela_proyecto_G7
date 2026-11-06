# Desarrollo y mediciones de semanas 11–13

**Código integrado en main; desarrollo de issues #1–#5 entregado.** Queda la auditoría independiente y los documentos/checker de Vera en #8. El usuario autorizó expresamente los merges de #14 y #15, realizados tras pasar CI. Este informe corresponde a la verificación del implementador; no suplanta la auditoría independiente ni declara aprobado el trabajo de Vera.

Correcciones de Dragon desarrolladas/publicadas en su rama (hasta 964f3dd), incluidas mediante merge en cueva. Cueva contiene las correcciones de entorno, carga, referencias SGD, entrenamiento, validadores y tablas. [PR #14 Dragon](https://github.com/AXL031/programacion_paralela_proyecto_G7/pull/14) · [PR #15 integración](https://github.com/AXL031/programacion_paralela_proyecto_G7/pull/15). Se conservaron las ramas personales y el commit concurrente de Dragon 2441322; no se forzó el historial.

## Evidencia y procedencia

El [índice de entrega](../bench/results/g7-release-20261105/manifest.json) referencia **63 muestras** originales: 12 cargas, 24 entrenamientos y 27 pasadas API (27.000 intentos). Identifica campaña, commit, ruta y SHA-256 de cada resultado. No renombra ni hace pasar datos de una campaña por otra.

Los artefactos de estas campañas conservan sus bytes originales mediante reglas de .gitattributes; sus SHA-256 se pueden verificar tanto en Git como dentro de los ZIP sin normalizar los saltos de línea. Los scripts y el código siguen usando sus reglas de formato habituales.

| Fuente | Código medido | Alcance utilizado |
|---|---|---|
| g7-complete-v2 | fa7b9c91d9cf773c87abe0f7567b79006588587d | load, training |
| g7-api-final-01 | fa23607ff6036062db1edc86737148a0879899fb | api |

Se excluyeron seis calentamientos: uno por caso de carga/entrenamiento; cada caso conserva cinco mediciones. API tiene tres pasadas por estado/concurrencia. El orden alternado/rotado original está en cada plan.json. La API se volvió a medir **en toda su matriz** tras corregir la separación entre integridad y meta; no se repitió selectivamente una pasada hasta obtener éxito.

La campaña g7-complete-v2 conserva sus 36 muestras válidas de carga/entrenamiento y sus intentos API originales, incluido un miss inesperado entre 1.000 respuestas del escenario caliente c10: HTTP 200 en 55,6 ms, 999 hits, meta incumplida. Su manifiesto original permanece failed. La campaña API nueva bootstrappea datos/modelo fuera de medición y registra ese hecho. Se comprobó igualdad de fuentes del producto/cómputo, configuración, snapshot y parámetros publicados entre fases; el generador/validador de medición tiene una revisión nueva, identificada por separado.

La campaña g7-complete-v1 conserva además el error BSON y las cargas previas; el piloto g7-real-pilot-01 y el smoke sintético se conservan por separado. No cuentan dentro de las 63 muestras finales. Los ZIP/checksums están en [bench/evidence](../bench/evidence/); el bruto ignorado por Git va incluido en esos ZIP accesibles al equipo.

## Implementación entregada

| Issue | Entregado |
|---|---|
| #1 Cueva | Entorno aislado, contrato, runner integrado, bloqueo, exportación, preservación y validación de bruto. Fase API independiente sin cambiar la matriz acordada. |
| #2 López | L1/L4 en MongoDB vacío, cargas nuevas, equivalencia lógica y logs independientes por sample_id para reset/conteos/verificación. |
| #3 Taco | Referencia S real obligatoria para Dn, rechazo de autorreferencias y comparaciones incompatibles, candidato previo a selección y modelo publicado comprobados por separado. |
| #4 Gerardo | S/D1/D2/D4, workers exactos con tareas, épocas/pasos completos, captura CPU/RSS y contenedores, estadísticas y tablas de speedup/eficiencia/recursos. Workers ya detenidos quedan fuera del conjunto observado. |
| #5 Dragon | Cliente Go concurrente probado, adaptador benchmark-v1, frío/caliente/fallback, precalentamiento con hits verificados y Redis restaurado, intentos/errores completos, proxy separado. |

## Método y entorno

Dataset real NYC TLC enero de 2024, período 1–15 enero: 2.964.624 filas leídas; **1.348.665** aceptadas/persistidas; 14.905 rechazadas y 1.601.054 fuera del período. Snapshot común: 378.720 ventanas / 378.457 ejemplos; train/validation/test 264.841/56.808/56.808. Las doce cargas tienen reused=false y verificación independiente en MongoDB.

Mismos epochs, batch global, learning rate, L2, semilla, encoder y splits para S/Dn; tolerancia por parámetro 1e-9 absoluta + 1e-9 relativa. Las tareas y los pasos se contrastan con las salidas de trainer y el diagnóstico previo a selección. La selección predictiva puede seguir publicando persistencia; no se declara mejora predictiva por equivalencia.

Docker 29.9.2, Compose 5.6.1, go version go1.27.2 linux/amd64. Motor con 16 CPU lógicas y 6.70 GiB. **Host compartido:** el contador histórico de contenedores ajenos en environment.json usaba un filtro de exclusión incorrecto y su valor cero no acredita aislamiento del host. El inventario posterior confirmó 11 contenedores ajenos (incluida la demo); se conserva aparte y se corrigió el filtro para próximas campañas. No se reescribió el entorno histórico. Las cuotas/GOMAXPROCS e IDs inmutables de imágenes quedan en environment.json. No se vació la caché del disco ni se detuvieron aplicaciones ajenas; los tiempos son mediciones bajo esas limitaciones.

## Tiempos

Medianas en segundos, cinco mediciones por caso. El total interno llega hasta publicación; el coste exterior del adaptador/container/CLI y el arranque de workers se conserva separado. L4 significa cuatro goroutines de procesamiento local, no cuatro nodos de ingesta. Dn son procesos TCP en contenedores de un host.

| Caso | n | Preparación | Cómputo | Evaluación | Publicación | Total |
|---|---:|---:|---:|---:|---:|---:|
| L1 | 5 | 1.977 | 37.928 | No disponible | 14.167 | 54.040 |
| L4 | 5 | 1.901 | 34.609 | No disponible | 14.001 | 50.689 |
| S | 5 | 18.023 | 14.334 | 0.071 | 0.020 | 32.448 |
| D1 | 5 | 21.725 | 25.498 | 0.080 | 0.020 | 45.482 |
| D2 | 5 | 22.383 | 18.427 | 0.076 | 0.020 | 40.950 |
| D4 | 5 | 21.447 | 15.040 | 0.073 | 0.017 | 36.785 |

Speedup L1/L4: **1.0661× total**; **1.0959× cómputo**.

| Caso/fase | S/Dn | D1/Dn | Eficiencia (D1/Dn)/n |
|---|---:|---:|---:|
| D1 / compute_seconds | 0.5622 | 1.0000 | 1.0000 |
| D2 / compute_seconds | 0.7779 | 1.3838 | 0.6919 |
| D4 / compute_seconds | 0.9530 | 1.6953 | 0.4238 |
| D1 / total_seconds | 0.7134 | 1.0000 | 1.0000 |
| D2 / total_seconds | 0.7924 | 1.1107 | 0.5553 |
| D4 / total_seconds | 0.8821 | 1.2364 | 0.3091 |

Los valores inferiores a uno representan ralentización. El coste distribuido incluye preparación/replicación del snapshot y sincronización TCP. Los tiempos por sí solos no prueban una causa única de cuello de botella. No se alteraron datos ni hiperparámetros para obtener aceleración y no se promete escalamiento entre servidores físicos.

Dispersión (media, mediana, mínimo/máximo y desviación muestral n−1), tiempos y fórmulas completas en [timings.csv](../bench/results/g7-release-20261105/timings.csv), [speedups.csv](../bench/results/g7-release-20261105/speedups.csv) y summary.json.

## Recursos

Mediana de CPU media/máxima y máximo conjunto de RAM **por muestra medida**. Se suman observaciones de contenedores alineadas (máximo desfase 250 ms); nunca los máximos de instantes distintos. CPU 100% equivale a un núcleo. CPU/RSS de procesos permanece en un scope separado; un total sin alineación suficiente queda no disponible.

| Caso | CPU media (%) | CPU máxima (%) | RAM máxima conjunta (MiB) |
|---|---:|---:|---:|
| L1 | 188.502 | 267.010 | 821.269 |
| L4 | 205.270 | 297.750 | 859.298 |
| S | 113.987 | 162.940 | 1262.740 |
| D1 | 124.197 | 186.640 | 1354.471 |
| D2 | 173.714 | 300.130 | 1496.940 |
| D4 | 263.678 | 405.650 | 2020.724 |

NDJSON, coverage.json y summary.json conservan identidad por proceso/servicio, timestamps, válidos/faltantes y cobertura real. La lectura Docker CLI puede superar un segundo; no es un registro continuo ni un máximo exacto del sistema. La ventana del colector puede incluir preparación fuera del reloj HTTP. Faltantes no equivalen a cero.

## API

REST directo desde cliente en la red aislada, conexiones persistentes y bucle cerrado con solicitudes en vuelo acotadas. Login, smoke y precalentamiento están fuera de medición. Frío: claves únicas tras vaciar Redis aislado. Caliente: inventario de 1.000 claves precalentado y verificado. No disponible: caída observada por readiness, predicción fallback y restauración posterior. Nunca se vacía ni detiene Redis de la demo.

Percentiles nearest rank del reloj de cliente hasta leer completamente la respuesta, incluidos los intentos fallidos. La mediana de p95 por pasada no es un percentil agrupado. La meta por caso exige p95 <100 ms y cero errores inesperados en todas sus pasadas. **Medición válida no implica meta cumplida**: cada fallo y desviación se conserva, baja el throughput de éxitos y produce objective_met=false.

| Caso | Pasadas/peticiones | Errores | Mediana p50 | Mediana p95 | Mediana p99 | Peor p95 | Máximo ms | Éxitos/s | Bajo 100 ms | Meta |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| API-cold-c1 | 3/3000 | 0 | 1.345 | 1.917 | 2.246 | 2.054 | 3.332 | 697.902 | 100.00% | Cumplida |
| API-cold-c10 | 3/3000 | 0 | 3.518 | 7.007 | 10.591 | 7.588 | 22.396 | 2499.058 | 100.00% | Cumplida |
| API-cold-c25 | 3/3000 | 0 | 7.448 | 12.368 | 14.451 | 13.277 | 20.091 | 3189.396 | 100.00% | Cumplida |
| API-unavailable-c1 | 3/3000 | 0 | 0.655 | 1.064 | 1.383 | 1.244 | 32.596 | 1086.520 | 100.00% | Cumplida |
| API-unavailable-c10 | 3/3000 | 0 | 1.059 | 2.858 | 30.641 | 5.294 | 50.265 | 5783.255 | 100.00% | Cumplida |
| API-unavailable-c25 | 3/3000 | 0 | 2.210 | 7.583 | 38.320 | 34.648 | 81.140 | 5585.102 | 100.00% | Cumplida |
| API-warm-c1 | 3/3000 | 0 | 0.994 | 1.467 | 1.899 | 1.667 | 14.681 | 923.488 | 100.00% | Cumplida |
| API-warm-c10 | 3/3000 | 0 | 1.669 | 3.716 | 5.031 | 3.791 | 7.511 | 5007.656 | 100.00% | Cumplida |
| API-warm-c25 | 3/3000 | 0 | 3.674 | 5.573 | 7.157 | 6.186 | 10.064 | 6444.780 | 100.00% | Cumplida |

El ensayo por proxy de demo se guarda aparte en g7-complete-v2/proxy-report.json: 1.000 predicciones, cero errores, p95 9,202312 ms y 1.000 hits observados. No se mezcla con los 27.000 intentos directos. No se usan tokens/credenciales como argumentos ni se guardan en reportes.

## Verificación y límites de cierre

- Suite Go con vet, race y MongoDB de integración configurado aprobada; tests del cliente HTTP aprobados. CI Go/React/PowerShell en los commits fusionados #14/#15 aprobada.
- 44 checks del runner, 46 de recursos/resumen, siete adicionales de integridad API (casos negativos de errores/causas/latencias/percentiles/throughput) y una regresión del inventario del host: ocho en la suite de evidencia actualizada.
- Índice de entrega: 100 comprobaciones compuestas de muestras/bruto/steps/modelos/preservación, además de las validaciones por intento/peso y hashes que ejecutan los helpers. Es verificación del implementador, no una certificación independiente de Vera.
- Smoke g7-integrated-smoke-01 con tres viajes sintéticos, dos workers ×27 tareas, candidatos equivalentes y miss/hit. Sus fixtures no se presentan como rendimiento.
- Scripts demo/semanas7–10 aprobaron JWT, predicción, Redis, WebSocket, telemetría e impacto con 1.348.665 viajes. Los doce archivos observados y los punteros/conteos de MongoDB de demo se conservaron durante las campañas. No se repitió en esta entrega el recorrido visual de navegador histórico.
- Único cierre pendiente de issues técnicos: auditoría independiente de Vera (#8), su checker con pruebas negativas y documentos SEMANA_11_13.md / VERIFICACION_SEMANA_13.json. No se crearon ni firmaron en su nombre.
- Pregunta social, mapa, mejora predictiva y despliegue de semanas14–15 son alcance general separado de los issues1–5 y siguen visibles. No se declara que todo el proyecto académico esté al100%.

## Reproducción

Campaña completa nueva, con las fuentes reales descargadas:

```powershell
./scripts/benchmark.ps1 -Action Prepare -Campaign g7-reproduce-01
./scripts/benchmark.ps1 -Action Run -Campaign g7-reproduce-01
./scripts/benchmark-proxy.ps1 -Campaign g7-reproduce-01
./scripts/benchmark.ps1 -Action Stop -Campaign g7-reproduce-01
./scripts/benchmark.ps1 -Action Export -Campaign g7-reproduce-01
```

Para medir exclusivamente toda la matriz API en otra fase, con bootstrap de datos/modelo excluido de medición:

```powershell
./scripts/benchmark.ps1 -Action Prepare -Campaign g7-api-new-01 -Config configs/benchmark-api.json
./scripts/benchmark-api-bootstrap.ps1 -Campaign g7-api-new-01
./scripts/benchmark.ps1 -Action Run -Campaign g7-api-new-01 -Config configs/benchmark-api.json
./scripts/benchmark.ps1 -Action Stop -Campaign g7-api-new-01
./scripts/benchmark.ps1 -Action Export -Campaign g7-api-new-01
```
