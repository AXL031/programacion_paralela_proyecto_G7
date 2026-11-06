# Escalabilidad y recursos — Gerardo, issue #4

**Actualización posterior al cierre técnico:** código de issues1–5 integrado en main mediante PR #14/#15, con autorización expresa del usuario y CI verde; 63 muestras originales y bruto verificable en el [cierre de desarrollo](CIERRE_DESARROLLO_11_13.md). Las campañas se identifican por fase y conservan los fallos anteriores. La auditoría independiente y los documentos/checker de Vera siguen en #8. El estado previo de este documento se conserva como historia; no representa pendientes de código actuales.


Avance de implementación para revisión, rama `gerardo`, 5 de noviembre de 2026 (Lima).
**La issue sigue pendiente: no se han ejecutado campañas reales S/D1/D2/D4 ni demostrado una mejora de rendimiento.**

## Entrega disponible

- `scripts/benchmark/statistics.psm1`: media, mediana, mínimo/máximo, desviación muestral, speedup y eficiencia. Rechaza series vacías, valores ausentes, texto, negativos, no finitos y denominadores no positivos. La desviación de una única observación es `null`.
- `scripts/benchmark-summary.ps1`: adaptador del contrato publicado. Revalida cada resultado con el validador de Cueva, exige el plan completo, identidades únicas, estado correcto, misma campaña/configuración y snapshot equivalente. Mantiene todos los IDs, identifica calentamientos y los excluye de las comparaciones. Conserva resultados desfavorables.
- `scripts/benchmark/resources.psm1` y `scripts/benchmark-resources.ps1`: colector de contenedores de la campaña y procesos Go PID 1. Valida el contexto y las etiquetas del proyecto antes de leer contadores. Descubre también loader/trainer temporales. No inicia, escala, detiene ni borra servicios.
- `tests/benchmark/test-gerardo.ps1`: pruebas offline de fórmulas, faltantes, RAM alineada, conversión de contadores, aislamiento y agregación de una matriz sintética completa. No necesita Docker ni Go instalado en Windows.

Las agregaciones se implementan como módulo PowerShell reutilizable, compatible con el punto de entrada `summary` publicado por Cueva. No se añaden tipos ni utilidades Go a `internal/benchmark/`: esa carpeta aún no existe en esta copia y no es necesaria para esta primera entrega. La ubicación/interfaz compartida queda sujeta a revisión con Cueva antes de integrar.

## Verificación en Windows sin descargar imágenes

Desde la raíz del repositorio, con PowerShell 7.2 o posterior:

```powershell
./tests/benchmark/test-gerardo.ps1
./tests/benchmark/test-runner.ps1
```

Los artefactos de prueba quedan bajo `.cache/benchmark-tests/`, `bench/results/test-*/`, `bench/raw/test-*/` y `data/bench/test-*/`, todos ignorados por Git. Son pequeños fixtures sintéticos; no son resultados del dataset real. El informe de la última prueba está en `.cache/benchmark-tests/gerardo-latest.json`.

Verificación ejecutada en esta entrega: **45 comprobaciones de Gerardo y 40 del runner satisfactorias**, incluida la llamada al resumen en un proceso PowerShell hijo. También pasó el análisis sintáctico de los cinco archivos PowerShell nuevos y `git diff --check`. Se ajustó únicamente la expectativa de adaptadores ausentes en la prueba existente: ahora se compara con los archivos efectivamente disponibles.

No se descargaron imágenes, se preparó una nueva base real ni se inició Docker para esta entrega. No se modificaron el trainer, maestro, workers, telemetría Go ni la demo. `go vet`, race e integración Go siguen pendientes para la validación conjunta; estos cambios solo añaden PowerShell y documentación.

Consulta local de solo lectura: motor Linux accesible, 12 CPU lógicas y aproximadamente 7.6 GiB de RAM asignados a Docker; host con aproximadamente 15.7 GiB de RAM. Había 0 contenedores en ejecución. `docker system df` informó 12.39 GB en imágenes, 1.348 GB en volúmenes y 8.391 GB en caché de construcción; son categorías de Docker y no deben sumarse como consumo físico exclusivo. No se eliminó ni modificó ninguno de esos recursos. Esto no demuestra todavía capacidad suficiente para D4.

## Interfaces

El resumen recibe los argumentos definidos en [CONTRATO_BENCHMARK.md](CONTRATO_BENCHMARK.md):

```powershell
./scripts/benchmark-summary.ps1 `
  -ContextPath .cache/benchmark/<campana>/context.json `
  -ManifestPath bench/results/<campana>/manifest.json `
  -OutputPath bench/results/<campana>/summary.json
```

El runner lo llama después de recibir todas las muestras válidas. Puede recalcularse desde el manifiesto y la evidencia, sin volver a medir. Produce `summary.json`, `summary-timings.csv` y `summary-speedups.csv`. El JSON también contiene las métricas de API entregadas por Dragon y resúmenes de recursos por muestra. Una fase sin instrumentar produce estadísticas `null` y su cantidad de faltantes; nunca un cero inventado. El entrenamiento exige tiempos de núcleo y total estrictamente positivos.

El colector recibe `ContextPath`, `SamplePath`, `OutputPath` y `StopFile`. Los dos últimos deben estar dentro del `raw_dir` de la campaña. Se niega a sobrescribir evidencia o adoptar una señal existente. Escribe una observación NDJSON por línea conforme al esquema del repositorio y un informe adicional `<OutputPath>.coverage.json`, con servicios, intervalos reales, faltantes, errores y SHA-256 del NDJSON.

Los adaptadores de López, Gerardo y Dragon deben arrancarlo como proceso hijo antes del trabajo, retener el PID y señalizar `StopFile` en `finally`; después deben esperar su salida, comprobar su código y cobertura, y evitar procesos huérfanos. El colector tiene además un límite de duración tomado del contexto. La integración de ese ciclo de vida en cada adaptador está pendiente de sus respectivos PR.

No ejecutar el colector contra la demo: exige el contexto aislado que genera el runner. Las lecturas Docker se restringen a IDs descubiertos por las tres etiquetas de proyecto/contrato/campaña y se vuelven a comprobar mediante inspección. No usa credenciales ni publica el contexto privado.

## Método y límites de los recursos

- **Proceso Go:** lee `/proc/1/stat`, `CLK_TCK` y `VmRSS` dentro de los contenedores Debian existentes. CPU es el incremento de tiempo de usuario+sistema dividido entre tiempo transcurrido; 100% equivale a un núcleo. RAM es RSS en bytes, con la misma semántica que la telemetría Go actual. No es heap. El primer punto, un reinicio o un contador inválido se marcan como no disponibles.
- **Contenedor:** usa un lote de `docker stats --no-stream --no-trunc`. CPU/memoria conservan la semántica y precisión mostradas por Docker. Las unidades SI y binarias se convierten explícitamente a bytes. Los timestamps identifican la recepción del lote; no garantizan lecturas simultáneas del kernel.
- **Cadencia:** el objetivo es aproximadamente un segundo, pero las llamadas CLI y las lecturas de procesos añaden latencia. Se guardan los intervalos reales; hay que revisar la cobertura antes de aceptar una campaña. Los trabajos breves pueden terminar antes de dos lecturas.
- **Cobertura mínima:** el colector falla si no observa recursos válidos del proceso principal requerido: loader para carga, trainer para S, maestro y la cantidad solicitada de workers para Dn, API para HTTP. Esto no sustituye la verificación de tareas aportadas ni demuestra cobertura continua de cada fase.
- **Agregación:** medias aritméticas de observaciones disponibles y máximos observados, con faltantes separados. Por scope, el conjunto incluye todos los servicios descubiertos en la muestra. Se emparejan puntos una sola vez, con diferencia máxima de 250 ms entre todos; si falta un servicio no se suma ese grupo. Nunca se suman máximos individuales ni se arrastran puntos antiguos. El total es `null` si no hay grupos alineados.
- **Alcance temporal:** el resumen cubre la vida del colector, no atribuye el máximo automáticamente al núcleo SGD. La integración debe conservar tiempos de fases y revisar puntos fuera/dentro de la fase que se informa. La lectura secuencial puede dejar el total de procesos sin puntos suficientemente alineados; se debe mostrar esa limitación.

No mezclar ni sumar scopes `process` y `container`. No sustituir ausencias por cero. El colector todavía necesita un smoke con Docker Linux real antes de afirmar que funciona con los servicios del grupo.

## Comparación requerida

Mismo snapshot y configuración; orden rotado; un calentamiento y cinco repeticiones medidas por cada caso:

| Caso | Cómputo | Estado de campaña real |
|---|---|---|
| S | Secuencial local | Pendiente |
| D1 | Distribuido, 1 worker | Pendiente |
| D2 | Distribuido, 2 workers | Pendiente |
| D4 | Distribuido, 4 workers | Pendiente |

Para núcleo SGD y total por separado, usando las medianas:

```text
speedup frente a S  = mediana(T_S)  / mediana(T_Dn)
speedup frente a D1 = mediana(T_D1) / mediana(T_Dn)
eficiencia          = speedup frente a D1 / n
```

Una eficiencia o speedup desfavorable se conserva. Las medianas de percentiles API por pasada no son percentiles de todas las solicitudes agrupadas. Los resultados de un host con contenedores no prueban escalamiento entre servidores; cada worker replica su snapshot en RAM.

## Condiciones pendientes para completar la issue

1. Cueva revisa esta interfaz/ubicación, integra los componentes y coordina el turno de ejecución. Su issue completo no tiene que estar cerrado para avanzar.
2. Taco entrega fases, diagnóstico del candidato SGD previo a selección y referencia secuencial verificable. El trainer actual todavía no los exporta. No se crea un `benchmark-training.ps1` que aparente cubrir ese contrato sin poder cumplirlo.
3. López deja un dataset/snapshot válido en el entorno aislado. El adaptador de entrenamiento debe verificar workers exactos, salud, ausencia de otro run y aportes reales de cada worker; integrar el colector y escalar únicamente el proyecto de benchmark.
4. Verificar espacio libre del disco que usa Docker, memoria disponible para D4 y Docker Linux operativo. Los aproximadamente 10 GB libres observados en C: permiten esta implementación offline, pero no certifican capacidad para imágenes, cachés y bases de la campaña completa. No se establece un mínimo ficticio ni se limpia almacenamiento automáticamente.
5. Ejecutar smoke real del colector, resolver cobertura/latencia y luego campañas S/D1/D2/D4 con recursos, candidatos equivalentes, evidencia accesible y resultados recalculables. Incorporar las tablas L1/L4 y API de sus responsables.
6. Completar validación conjunta y PR de `gerardo` hacia `main`, con revisión de Cueva y evidencia para Vera. Ninguna issue se cierra con esta entrega parcial.
