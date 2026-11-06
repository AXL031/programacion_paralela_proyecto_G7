# Plan de avance hasta la semana 13 y comparación con la versión actual

**Actualización posterior al cierre técnico:** código de issues1–5 integrado en main mediante PR #14/#15, con autorización expresa del usuario y CI verde; 63 muestras originales y bruto verificable en el [cierre de desarrollo](CIERRE_DESARROLLO_11_13.md). Las campañas se identifican por fase y conservan los fallos anteriores. La auditoría independiente y los documentos/checker de Vera siguen en #8. El estado previo de este documento se conserva como historia; no representa pendientes de código actuales.


Fecha: **5 de noviembre de 2026, Lima**.

Reparto entre integrantes, ramas, dependencias, issues y revisión de PR: [DISTRIBUCION_SEMANAS_11_13.md](DISTRIBUCION_SEMANAS_11_13.md).

**Estado: propuesta de trabajo. Este documento no implementa cambios ni certifica actividades nuevas como terminadas.** Se preparó por solicitud de planificar primero. La ejecución del plan queda para una etapa posterior.

## 1. Objetivo y punto de partida

Completar las actividades de las semanas 11, 12 y 13 del cronograma: formalizar la contraparte local, ejecutar comparaciones reproducibles de carga y entrenamiento, medir la API bajo concurrencia, evaluar escalabilidad y recursos, y realizar los ajustes de código que justifiquen los resultados.

La referencia es el checkout actual sobre el commit `95894e4`, incluyendo la actualización local del README que ya existía antes de esta planificación. No se debe confundir esa referencia con el commit anterior `99100f2` utilizado por la auditoría histórica. Al iniciar el desarrollo se registrarán el commit y el diff efectivo para conservar una comparación exacta.

Fuentes revisadas:

- [Cronograma original](Cronograma_Proyecto9_Go_BigData.xlsx), hoja **Hoja 1**, filas **16 a 23**, columnas **H a J**. Las asignaciones semanales se identifican por relleno de las celdas.
- [README y matriz de avance](../README.md), incluida su actualización documental del 5 de noviembre.
- [Auditoría y evidencia de la semana 10](AUDITORIA_SEMANA_10.md) y [registro de verificación local](VERIFICACION_LOCAL_SEMANA_10.json).
- Código del loader, trainer, maestro/workers, selección de modelo, API, telemetría, Compose y pruebas existentes.

El Excel asigna semanas académicas, pero no fechas calendario, responsables ni ponderaciones. Este plan no inventa esas asignaciones.

### Qué ya existe

| Componente | Situación actual comprobada en código o evidencia guardada |
|---|---|
| Datos | Dataset histórico documentado de 1,348,665 viajes persistidos, 378,720 ventanas y 378,457 ejemplos. Los originales Parquet y catálogo están presentes en esta copia. Los conteos de MongoDB corresponden a evidencia histórica, no a una consulta nueva de esta planificación. |
| Carga local | Un proceso Go con lectura por bloques, goroutines/channels, validación y lotes MongoDB. `loader -workers` ya permite cambiar el paralelismo local. |
| Entrenamiento local | `trainer -mode sequential`, sin parameter server entre nodos. |
| Entrenamiento distribuido | Maestro TCP y workers independientes. El cálculo se divide por índices de cada batch; cada worker carga una copia del snapshot. |
| Tiempos | Loader: segundos y filas/s. Runs: preparación, entrenamiento y evaluación. |
| API | REST/JWT, Redis, WebSocket y pruebas funcionales. Hay latencias históricas de consultas secuenciales. |
| Recursos | CPU y RSS de los procesos Go del maestro/workers, con muestreo y heartbeats. Falta una serie comparable de recursos de loader/trainer y del conjunto de contenedores durante los ensayos. |
| Corrección | Pruebas pequeñas de loader 1/4 goroutines y entrenamiento TCP 1/2/4 workers; no sustituyen benchmarks sobre el dataset real. |
| Comparación actual | `scripts/train-demo.ps1` compara una ejecución por modo y los pesos publicados. Declara correctamente que es una verificación funcional, no un benchmark. |

La auditoría local del 13 de octubre registró **13.329 s secuencial y 19.526 s distribuido**, y dos pasadas HTTP de 100 consultas secuenciales con p95 de **10.439 y 7.0149 ms**. Son antecedentes de esa ejecución. El README conserva también tiempos de otras ejecuciones; no se mezclarán como si fueran repeticiones de un mismo experimento.

Durante esta revisión el motor Docker no estaba accesible y `docker desktop start` falló al buscar una clave de registro. Esto queda como una comprobación previa a resolver en el entorno de ejecución; no demuestra que la instalación histórica haya dejado de funcionar. No se ejecutaron nuevos entrenamientos ni benchmarks.

## 2. Alcance por semana y criterio de cierre

| Semana / fila del Excel | Actividad | Trabajo previsto | Se podrá cerrar cuando… |
|---|---|---|---|
| 11 / 16 | Cargador en un solo proceso con goroutines locales | Reutilizar el loader existente y documentar su configuración y límites. | Carga completa con 1 y 4 goroutines produce los mismos conteos, dataset y snapshot; cada medición confirma `reused=false`. |
| 11 / 17 | SGD local sin parameter server | Reutilizar el trainer secuencial y fijar la referencia numérica. | Ejecuta con el mismo snapshot, splits, semilla e hiperparámetros que el distribuido y permite comprobar el candidato SGD previo a la selección. |
| 11 / 18 | Instrumentación de tiempos de ambas versiones | Unificar registro de fases, tiempo total, configuración, recursos y entorno. | Cada muestra tiene identidad, unidades, alcance y evidencia bruta suficientes para reproducirla. |
| 12 / 19 | Pruebas de carga y entrenamiento comparadas | Ejecutar ensayos repetidos de ingesta local 1/4 goroutines y entrenamiento secuencial/distribuido con 2 workers. | Existen repeticiones válidas y comparables, con comprobaciones de datos y corrección numérica. Se explica que la ingesta actual es local. |
| 12 / 20 | Latencia API, objetivo <100 ms | Medir HTTP con concurrencia, caché fría, caliente y Redis no disponible. | Se publican percentiles, máximo, errores, peticiones/s, caché observada y proporción bajo 100 ms; cada caso declara si alcanza el objetivo operativo definido. |
| 13 / 21 | Rendimiento y escalabilidad distribuida | Extender entrenamiento a 1, 2 y 4 workers y medir recursos. | Cada cantidad de workers tiene repeticiones válidas, aportes reales de todos los workers y CPU/RAM registradas. |
| 13 / 22 | Cuadro de tiempos, speedup y recursos | Consolidar resultados y explicar sobrecostes y límites del host. | Tabla reproducible con tiempos, dispersión, speedup, eficiencia y recursos, vinculada a las muestras originales. |
| 13 / 23 | Ajustes finales de código | Corregir problemas demostrados y volver a medir los casos afectados. | Hay registro del diagnóstico, cambio y validación antes/después. Si no hay una optimización segura justificada, se documenta esa conclusión y los ajustes de instrumentación/verificación realizados. |

**Decisión de alcance:** llegar hasta la semana 13 es razonable porque sus mediciones usan la misma infraestructura de comparación que la semana 12. Añade casos y análisis; no exige reconstruir el sistema ni crear otra aplicación.

Cerrar estas actividades no permite declarar terminado todo lo solicitado hasta esa semana: sigue abierta la brecha histórica de la pregunta social de la semana 7. Su resolución se explica en la sección 10.

## 3. Diseño de los experimentos

### Reglas comunes

1. Usar `configs/demo.json` como selección de datos y `configs/training.json` como configuración principal. Conservar el período del 1 al 15 de enero de 2024 en Nueva York, ventanas de 15 minutos, checksums y splits temporales.
2. Compilar y descargar antes de medir. Usar las mismas imágenes para todos los casos del experimento y registrar sus identificadores, versiones de Go/Docker/Compose, CPU/RAM asignadas al motor y límites de contenedor.
3. Crear un proyecto Compose de benchmarks separado, con MongoDB, Redis, puertos y salida de artefactos propios. Las mediciones no deben cambiar el dataset/modelo activo de la demo ni sus sesiones.
4. Para cada caso, ejecutar **un calentamiento no incluido y cinco repeticiones medidas**. Registrar duración total prevista con un ensayo piloto. Si se acuerda reducir a tres repeticiones, declararlo y no combinar campañas con protocolos distintos.
5. Alternar o rotar el orden de los casos entre rondas, con orden/semilla registrados. No ejecutar casos de rendimiento en paralelo ni dejar otro entrenamiento activo. Las pruebas Go y la compilación se realizan fuera de la ventana de medición.
6. Conservar los errores y muestras fallidas con causa. No repetir selectivamente hasta obtener un tiempo favorable. Si se corrige una condición que invalida la campaña, iniciar una campaña nueva.
7. Informar mediana, media, mínimo, máximo y desviación estándar muestral. Con cinco repeticiones se obtiene una comparación exploratoria; no se prometerá una mejora estadística universal.
8. Identificar las condiciones de caché de archivos y base de datos. El calentamiento del sistema operativo no equivale a reutilizar un dataset cargado. No presentar estas mediciones como lectura de disco completamente fría.

### Matriz de carga

| Caso | Proceso | Paralelismo | Persistencia y datos |
|---|---|---:|---|
| L1 | Loader local | 1 goroutine de procesamiento | MongoDB vacío del ensayo, mismo Parquet, filtro y lotes |
| L4 | Loader local | 4 goroutines de procesamiento | MongoDB vacío del ensayo, mismo Parquet, filtro y lotes |

Mantener el mismo `GOMAXPROCS` y presupuesto de CPU en L1/L4, registrando que un worker de procesamiento no elimina las otras goroutines del pipeline. Medir parseo/validación, escritura y exportación si el piloto requiere separar cuellos de botella, además del total ya existente.

Cada ensayo necesita una base vacía exclusiva o un reinicio controlado de su propia base. Rechazar como medición de ingesta cualquier resultado con `reused=true`: esa ruta recupera un manifiesto existente y conserva sus estadísticas históricas. No basta con volver a ejecutar el comando sobre la misma base.

Comparar filas leídas, aceptadas, rechazadas por causa, fuera del período y persistidas; verificar conteos MongoDB y SHA-256 del snapshot. El orden físico de inserción de los viajes puede variar sin cambiar el resultado lógico.

**No se añadirá un loader multinodo como parte de este cambio.** El cronograma sitúa el cargador concurrente dentro del desarrollo distribuido, pero el código existente procesa la ingesta en un solo proceso. El informe distinguirá carga local concurrente de entrenamiento distribuido y dejará expresa esa interpretación de alcance.

### Matriz de entrenamiento

| Caso | Cómputo SGD | Procesos de cómputo principales |
|---|---|---|
| S | Secuencial local | Trainer |
| D1 | Distribuido TCP | Maestro + 1 worker |
| D2 | Distribuido TCP | Maestro + 2 workers |
| D4 | Distribuido TCP | Maestro + 4 workers |

Mantener épocas, batch global, learning rate, L2, semilla, datos y normalización. Usar inicialmente un `GOMAXPROCS=1` por proceso de entrenamiento, como en la configuración actual. Registrar también cuotas de CPU: `GOMAXPROCS` por sí solo no fija una cuota de contenedor. En distribuido aumenta el número de procesos y el presupuesto potencial total; el informe debe mostrarlo.

Antes de cada run, comprobar cantidad exacta de workers conectados, identidad, salud y ausencia de entrenamiento activo. Después, exigir estado completo, número esperado de pasos y tareas aportadas por cada worker. No medir D4 si solo dos workers contribuyeron.

Separar **preparación**, **núcleo de entrenamiento**, **evaluación/selección**, **publicación** y **tiempo total observado**. Explicitar si la inicialización TCP, la carga del snapshot en workers y el arranque de contenedores están incluidos. Medir el arranque aparte; las comparaciones principales se hacen con servicios preparados. D1 permite estimar el sobrecoste de la arquitectura TCP frente a S.

#### Verificar SGD antes de publicar

Actualmente `training.Execute` sustituye los pesos del candidato por el resultado de `ml.Select`. Si la validación elige persistencia en S y D2, sus pesos publicados pueden ser idénticos aunque los candidatos fueran diferentes.

El desarrollo deberá conservar diagnósticos del candidato **antes** de esa selección para el runner de benchmarks: pesos o un artefacto diagnóstico local, pérdida, dimensiones y métricas de validación. Comparar los candidatos con tolerancia absoluta y relativa fijadas antes de los ensayos; empezar por `abs <= 1e-9 + 1e-9 * max(abs(a), abs(b))` por parámetro y revisar su pertinencia con las pruebas numéricas existentes. Registrar la diferencia máxima y el criterio, sin confundir tolerancia con igualdad bit a bit.

Mantener separados el candidato entrenado y el modelo efectivamente publicado. Preservar el uso exclusivo de validación para la selección; el test final sigue destinado a evaluación. Los diagnósticos no se expondrán como un cambio obligatorio del contrato público de predicción.

### Matriz de API

Endpoint principal: `POST /api/v1/predictions` con JWT válido. Medir desde el cliente HTTP el tiempo completo hasta leer la respuesta, incluyendo red local, autenticación y serialización; el `latency_ms` interno será solo un dato auxiliar.

| Escenario | Preparación | Comprobación |
|---|---|---|
| Redis disponible, caché fría | Redis aislado vacío; consultas válidas distintas por zona/origen, sin repetir claves dentro de la pasada | `cache_hit=false` en las respuestas medidas |
| Redis disponible, caché caliente | Precalentar fuera de medición un conjunto fijo de consultas | `cache_hit=true` en las respuestas medidas |
| Redis no disponible | Interrumpir únicamente el Redis del entorno de benchmarks y verificar la indisponibilidad | Respuestas correctas mediante fallback; fallos y tiempos observados quedan registrados |

Para cada escenario: concurrencia **1, 10 y 25**, **1,000 solicitudes medidas por pasada** y **tres pasadas independientes**. El conjunto de consultas válidas se construye a partir del dataset/modelo activo; se verifica que hay suficientes claves únicas para las pasadas frías y se vacía solo el Redis aislado entre ellas.

El generador mantendrá como máximo esa cantidad de solicitudes en vuelo y reutilizará conexiones. Se documentará como una prueba de concurrencia con clientes que esperan respuesta, no como garantía frente a cualquier tasa de llegada externa. Primero habrá un smoke pequeño de validez de consultas. El login y el precalentamiento quedan fuera de los tiempos de predicción.

Registrar p50, p95, p99, máximo, errores HTTP, timeouts, fallos de validación de respuesta, solicitudes por segundo y proporción de respuestas por debajo de 100 ms. Conservar también latencia de los intentos fallidos para que los percentiles de éxito no oculten problemas de disponibilidad.

El Excel dice **objetivo <100 ms**, sin definir percentil. Para este plan se propone **p95 <100 ms y cero errores inesperados en cada caso medido** como criterio operativo. Informar además máximo y porcentaje que excede 100 ms para permitir una lectura literal de la meta. Si no se alcanza, la medición se da por realizada y la meta queda como incumplida; no se marca como lograda por medirla.

La ruta directa a la API será la referencia de medición. Una pasada por el proxy web servirá para comprobar el recorrido de la demo, con resultados separados. No se mezclarán REST y WebSocket en una misma estadística.

## 4. Recursos, fórmulas e interpretación

Capturar recursos aproximadamente cada segundo durante las fases medidas, con marcas de tiempo que permitan alinearlos con los runs. Para contenedores breves o fases subsegundo, registrar la cobertura y añadir contadores de CPU acumulada o muestreo más frecuente si hace falta; no inventar picos ausentes.

- **Procesos Go:** CPU y RSS del trainer/loader o del maestro y todos los workers. Reutilizar la telemetría existente donde esté disponible y extender su captura a jobs locales.
- **Contenedores:** registrar estadísticas de CPU/memoria del motor Docker para jobs, workers, maestro, MongoDB, Redis y API según el caso. Sus métricas no son intercambiables con RSS del proceso.
- **Agregados:** CPU media y máxima; RAM máxima observada del conjunto calculada sumando muestras alineadas, no sumando máximos ocurridos en momentos distintos. Registrar por separado cada servicio y el conjunto de cómputo.
- **Significado:** 100% CPU del proceso equivale a un núcleo. RAM de los procesos Go es RSS, distinta del heap y de la memoria total del contenedor.
- **Cobertura:** muestras válidas, intervalo real, muestras ausentes y muestras antiguas. RAM faltante se informa como no disponible, nunca como cero.

Fórmulas, aplicadas a medianas de tiempos comparables:

| Indicador | Definición |
|---|---|
| Speedup de ingesta | `mediana(T_L1) / mediana(T_L4)` |
| Speedup frente a local | `mediana(T_S) / mediana(T_Dn)` |
| Escalamiento dentro del distribuido | `mediana(T_D1) / mediana(T_Dn)` |
| Eficiencia por worker | `[mediana(T_D1) / mediana(T_Dn)] / n` |
| Throughput de carga | Filas de origen leídas / segundos de carga; incluir también viajes válidos/s |
| Throughput API | Solicitudes completadas / segundos de la ventana medida; separar éxitos y total |

Calcular speedup tanto para el núcleo SGD como para el tiempo total, claramente etiquetados. Un valor menor que 1 indica que el caso distribuido fue más lento. La eficiencia indicada usa D1 como referencia y cuenta workers; el maestro y su consumo se reportan aparte.

El experimento evalúa un tamaño de problema fijo en contenedores de **una sola computadora**. No demuestra escalamiento entre servidores ni crecimiento lineal con los datos. El snapshot completo por worker puede aumentar RAM; la sincronización, serialización y red pueden aumentar el tiempo. Estas son hipótesis a contrastar, no conclusiones anticipadas.

## 5. Secuencia de implementación futura

### Etapa A. Congelar referencia y preparar el entorno

1. Registrar commit, cambios locales, configuraciones, imágenes, datos y checksums de la versión de partida.
2. Verificar Docker Linux operativo y recursos disponibles. Resolver el fallo de arranque observado con la menor intervención necesaria; evitar reinstalaciones como primer paso.
3. Crear aislamiento de benchmarks con nombres, puertos, volúmenes, base de datos y directorios propios. Limitar cualquier limpieza a esos recursos creados para el ensayo.
4. Ejecutar smoke con fixtures y comprobar que la demo conserva su dataset/modelo.

**Salida:** manifiesto del experimento y entorno de pruebas disponible.

### Etapa B. Formalizar semana 11 e instrumentación

1. Reutilizar CLI y núcleos existentes, sin duplicar algoritmos.
2. Añadir captura uniforme de tiempos y recursos para loader, trainer y distribuido.
3. Guardar candidato SGD previo a selección y crear su verificación numérica.
4. Implementar runner configurable con validación de casos, calentamientos, repeticiones, errores y salida estructurada.

**Salida:** runner probado en fixtures y contratos de evidencia definidos.

### Etapa C. Ejecutar semana 12

1. Carga L1/L4 completa y repetida sobre bases vacías, con comprobación de equivalencia.
2. Entrenamiento S/D2 sobre el mismo snapshot, con corrección del candidato y de la publicación.
3. Prueba API en la matriz propuesta, aislando cada condición de caché.
4. Guardar resultados brutos y revisar validez antes de agregarlos.

**Salida:** comparación local/distribuida y reporte de latencia con cumplimiento por escenario.

### Etapa D. Extender a semana 13

1. Incorporar D1/D4 y completar las repeticiones con contribución real de todos los workers.
2. Consolidar curvas y tabla de tiempos, speedup y recursos.
3. Examinar si el coste dominante es preparación, SGD, comunicación, persistencia o memoria.

**Salida:** evaluación de escalabilidad con límites y diagnóstico explícitos.

### Etapa E. Ajustar, contrastar y cerrar

1. Elegir cambios pequeños sustentados por los resultados: por ejemplo, reducir un coste repetido de serialización o preparación si se demuestra que es significativo.
2. Cambiar una variable a la vez. Conservar mediciones anteriores, repetir los casos afectados y comprobar corrección/calidad.
3. Evitar cambiar simultáneamente épocas, datos o batch para presentar una aceleración que ya no sería comparable. Una exploración de configuración se publicará como experimento aparte.
4. Ejecutar las verificaciones de cierre y actualizar la matriz del README solo con evidencias nuevas válidas.
5. Documentar la comparación final con la referencia congelada y el estado de cada brecha.

**Salida:** cambios revisables, resultados antes/después e informe de semanas 11–13.

## 6. Archivos afectados y entregables previstos

Los nombres nuevos de esta tabla son propuestas; **no existen por el hecho de figurar en el plan**.

| Archivo o área | Acción prevista | Propósito |
|---|---|---|
| `docker-compose.benchmark.yml` | Crear configuración de ensayo | Aislamiento de servicios, puertos, recursos y almacenamiento sin cambiar la demo diaria. |
| `configs/benchmark.json` | Crear | Casos, repeticiones, concurrencias, tolerancias y criterios de la campaña. |
| `scripts/benchmark.ps1` | Crear | Orquestar preparación, carga nueva, escalado, entrenamiento y captura de evidencia en Windows. |
| `cmd/benchmark-api/` | Crear utilidad Go con bibliotecas existentes/estándar | Generar carga HTTP concurrente y resultados estructurados sin exponer credenciales. |
| `internal/benchmark/` | Crear si hace falta compartir lógica | Resúmenes, percentiles, validación y formato de resultados; no duplicar ML. |
| `internal/training/run.go` | Extender instrumentación | Captura previa a selección, publicación y fases comparables. Mantener lectura de artefactos anteriores. |
| `cmd/loader/main.go`, `internal/loader/`, `cmd/trainer/main.go` | Extender solo donde falten diagnósticos | Tiempos, recursos y salidas reutilizables por el runner. |
| `internal/cluster/master/`, `internal/telemetry/` | Ajustes condicionados al diagnóstico | Exponer/capturar fases y muestras necesarias; optimizar únicamente si la medición lo justifica. |
| `scripts/check-weeks-11-13.ps1` | Crear | Validar integridad de resultados, matriz completa y criterios de cierre. |
| `bench/results/<campaña>/` | Crear resultados versionables y compactos | Manifiesto, resúmenes JSON/CSV y evidencias suficientes para rastrear los agregados. |
| `bench/raw/<campaña>/` y `data/bench/<campaña>/` | Guardar salidas voluminosas locales | Runs completos, muestras de recursos, snapshots y logs; definir retención. `bench/raw/` y `data/` ya están ignorados por Git. |
| `docs/SEMANA_11_13.md` | Crear al ejecutar | Método, resultados, diferencias, limitaciones y comandos reproducibles. |
| `docs/VERIFICACION_SEMANA_13.json` | Crear al ejecutar | Evidencia resumida, campaña, estado por actividad y enlaces a resultados. |
| `README.md` y `docs/PLAN_DESARROLLO.md` | Actualizar al cerrar | Estado real, acceso a comparación y siguiente trabajo. Conservar historia identificada por fecha. |

La SPA actual puede mantenerse para esta entrega: el cuadro comparativo de semana 13 se entregará inicialmente como informe y CSV. Llevar los benchmarks al panel React es opcional y requiere agregar consulta/persistencia de resultados; no es necesario para cerrar las filas 21–23 del Excel.

Cada muestra deberá guardar al menos campaña, caso, repetición, fecha UTC y referencia horaria, commit/diff, entorno, configuración, dataset/snapshot, tiempos, recursos disponibles, validaciones, estado y causa de fallo. Los resultados de API añadirán identidad de modelo y distribución de caché. No guardar JWT, contraseñas ni tokens internos en la evidencia.

## 7. Diferencias esperadas frente a la versión actual

| Aspecto | Versión actual | Versión prevista hasta semana 13 |
|---|---|---|
| Propósito demostrado | Demo funcional de servicios y entrenamiento | Demo más evaluación reproducible de rendimiento |
| Contraparte local | Ya implementada | Formalizada y verificada con condiciones comparables |
| Ingesta | Concurrente local; una cifra funcional histórica | L1/L4 con cargas nuevas repetidas, equivalencia y recursos |
| Entrenamiento real medido | Una comparación funcional S/D2 por ejecución del script | S/D1/D2/D4, calentamiento, repeticiones y fases separadas |
| Corrección numérica comparada | Pesos publicados; posible persistencia en ambos modos | Candidato SGD previo a selección más modelo publicado |
| API | Smoke y latencia secuencial histórica | Concurrencia 1/10/25, tres escenarios de Redis, percentiles, errores y throughput |
| CPU/RAM | Telemetría en vivo y capturas puntuales | Series por ensayo, cobertura y agregados con alcance definido |
| Speedup | No demostrado | Calculado y explicado, incluso si muestra ralentización |
| Ajustes de rendimiento | Sin diagnóstico comparativo repetido | Cambios sustentados por mediciones antes/después |
| Evidencia | Archivos funcionales y auditoría de semana 10 | Campañas identificadas, datos brutos y resúmenes trazables |
| Experiencia de uso | Consulta, entrenamiento y telemetría actuales | Puede conservarse; la diferencia principal está en validación, instrumentación e informe |

El cambio no promete mejor MAE/RMSE ni que cuatro workers sean más rápidos. El resultado válido puede ser que el coste distribuido supere al secuencial para este modelo/dataset/host. Explicar ese resultado forma parte de la semana 13.

## 8. Validación y criterios generales de aceptación

### Pruebas necesarias para el cambio

- Reutilizar las pruebas de equivalencia del loader y TCP con 1/2/4 workers. Añadir cobertura significativa para el candidato SGD antes de selección y para las nuevas reglas del runner.
- Verificar que el runner rechaza cargas reutilizadas, workers insuficientes, snapshots distintos y resultados incompletos; conserva errores y no genera un cierre exitoso con casos faltantes.
- Probar percentiles/agregados con entradas conocidas, cálculos de speedup, tiempos inválidos y muestras de recursos ausentes. Verificar que una respuesta errónea o con caché inesperada no pasa como muestra válida.
- Ejecutar formato y `go vet ./...`, y `go test -race -count=1 ./...` en el entorno Docker con MongoDB de integración configurado.
- Ejecutar los chequeos funcionales existentes de demo/semanas 7–10 y el nuevo chequeo de semanas 11–13. Si cambia React, compilarlo y revisar el recorrido del navegador afectado.
- Comprobar después del ensayo que la demo conserva sus datos/modelo y responde con autenticación, caché y WebSocket. Cerrar los recursos exclusivos de benchmark según la retención acordada.

### Condición para declarar el avance

1. Ninguna actividad se marca terminada solo por tener un script.
2. Los casos requeridos tienen resultados válidos y evidencia de corrección; los fallos quedan visibles.
3. Los agregados se pueden recalcular a partir de las muestras conservadas.
4. La meta de API se informa por escenario como cumplida/incumplida, con percentil y errores explícitos.
5. Los ajustes no degradan contratos, autenticación ni corrección; cualquier variación de calidad se informa.
6. El informe describe resultados reales y la comparación con la versión de partida, sin presentar mediciones de octubre como resultados nuevos.
7. Se mantienen visibles las brechas de contexto general. Si un criterio no pasa, se identifica como pendiente y se describe la causa.

## 9. Orden, esfuerzo y dependencias

Estimación inicial orientativa de **trabajo efectivo de una persona**, no fechas de entrega:

| Bloque | Esfuerzo inicial |
|---|---:|
| Referencia, entorno y aislamiento | 2–4 horas |
| Instrumentación, candidato y runner | 6–10 horas |
| Matriz de carga/entrenamiento y API | 4–6 horas |
| Escalabilidad, recursos y análisis | 3–5 horas |
| Ajustes, regresión y documentación | 5–8 horas |
| **Total hasta semana 13** | **20–33 horas** |

Respecto de cerrar solo semana 12, la ampliación a semana 13 reutiliza el runner y añade D1/D4, recursos consolidados y ajustes: aproximadamente **5–9 horas adicionales**, incluidas en el total. La diferencia es moderada mientras no aparezca un defecto importante ni una limitación de memoria con cuatro workers.

La duración de los procesos automáticos se afinará con el piloto; averías de Docker, espacio insuficiente o fallos de dependencias pueden ampliar el calendario. El [reparto por integrante](DISTRIBUCION_SEMANAS_11_13.md) concreta responsables y ramas; las disponibilidades y fechas de entrega se acordarán con el grupo.

Dependencia principal: **A → B → C → D → E**. Las mediciones formales no deben adelantarse a la definición de comparabilidad y captura de evidencia.

## 10. Brechas que no deben desaparecer del informe

| Tema | Tratamiento en este avance |
|---|---|
| Pregunta social de semana 7 | La pregunta implementada trata actividad observada; no permite medir demanda no atendida. Preparar una justificación del alcance y obtener alineación con el criterio docente, o definir una ampliación de datos como trabajo separado. Este plan no presupone que el docente ya aceptó el cambio ni declara la brecha cerrada. |
| Mapa de zonas | Está en el contexto general registrado en la auditoría, sin actividad propia en el Excel. Mantenerlo pendiente y definir su entrega en el plan general; no convertirlo implícitamente en requisito de los benchmarks. |
| Mejora predictiva | Actualmente validación eligió persistencia. Informar el resultado; cambiar de modelo o de dataset no forma parte del benchmark principal. |
| Memoria de cuatro workers | Cada worker mantiene su snapshot completo. Medir el consumo antes de la campaña; si no cabe, documentar el límite y resolverlo antes de declarar completado D4. |
| Despliegue final | Compose de entrega, instalación limpia, segundo entorno y demo final siguen en semanas 14–15. El Compose de benchmark sirve para ensayos y no cierra automáticamente esas actividades. |
| Checkpoints y reasignación | Son ampliaciones del plan general, sin fila propia en las actividades 16–23. No se añaden a este cambio salvo una necesidad demostrada y una ampliación explícita del alcance. |

## 11. Checklist para ejecutar este plan en una etapa posterior

- [ ] Congelar y registrar la referencia efectiva del checkout.
- [ ] Verificar Docker Linux y capacidad de CPU/RAM/disco.
- [ ] Preparar aislamiento de benchmarks y comprobar conservación de la demo.
- [ ] Formalizar contraparte local y tiempos por fase.
- [ ] Capturar y comprobar candidatos SGD previos a selección.
- [ ] Implementar y verificar runner, captura de recursos y generador HTTP.
- [ ] Ejecutar L1/L4 con cargas nuevas y equivalencia de datos.
- [ ] Ejecutar S/D2 y la matriz de API de semana 12.
- [ ] Completar D1/D4 con recursos y participación de todos los workers.
- [ ] Consolidar tiempos, dispersión, speedup y eficiencia.
- [ ] Realizar ajustes justificados y repetir casos afectados.
- [ ] Pasar comprobaciones de código, integración y demo.
- [ ] Entregar comparación antes/después y actualizar estados con evidencia.
- [ ] Mantener identificadas pregunta social, mapa y semanas 14–15.

**Resultado de esta etapa de planificación:** un alcance y un procedimiento completos para desarrollar después hasta semana 13. Ninguna casilla de ejecución se cierra con la creación de este documento.
