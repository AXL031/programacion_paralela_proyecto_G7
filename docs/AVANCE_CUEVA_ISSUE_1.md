# Avance de Cueva: entorno y orquestación de benchmarks

**Actualización de auditoría del 5 de noviembre de 2026:** la primera entrega #7 ya se fusionó; #9 (colector/resumen) y #10 (instrumentación SGD) también están en `main`. #11 de carga sigue en revisión y #12 de Dragon se abrió en borrador. Vera ya tiene acceso e issue #8. El runner necesita reforzar la validación de la referencia secuencial antes de certificar entrenamiento. Consulta [estado actual, hallazgos y pendientes por integrante](AUDITORIA_ISSUES_PR_2026_11_05.md). Las secciones siguientes conservan el estado histórico de la primera entrega y sus evidencias.

Fecha: **5 de noviembre de 2026, Lima**. Rama: `cueva`. Issue: [#1](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/1).

**Entrega parcial para revisión; el issue permanece abierto.** Se implementa la base independiente sobre el merge aprobado del PR #6 (`77d8360`). La integración de componentes reales aún depende de #2–#5.

## Cambio frente a la versión anterior

Antes había un plan y una demo funcional con scripts propios, sin entorno dedicado de ensayos ni interfaz común de evidencia. Ahora hay:

- Compose independiente con MongoDB/Redis/maestro/workers/API, jobs de loader/trainer y servicio de pruebas Go. Usa namespace, volúmenes, red, puerto, credenciales y datos exclusivos por campaña.
- `configs/benchmark.json`: protocolo acordado y mapa de adaptadores, sin simular que los componentes pendientes ya existen.
- `scripts/benchmark.ps1` y módulo: acciones Plan/Prepare/Smoke/Run/Stop/Export, bloqueo de host, referencia congelada, inventario SHA-256, límites explícitos, supervisión de procesos/timeout, evidencia de errores y validación de resultados.
- Contrato publicado en [CONTRATO_BENCHMARK.md](CONTRATO_BENCHMARK.md), esquemas JSON y formato NDJSON de recursos. El runner verifica identidad, conteos, caché, candidatos previos a selección y checksums; los componentes producen las evidencias.
- Smoke real de infraestructura con fixture sintético y pruebas independientes del runner con adaptadores controlados.
- Preservación antes/después de la demo y exportación local de evidencia sin credenciales/contexto privado.

No se cambian los motores de ML, loader, API ni la interfaz React en esta entrega. No hay campañas reales ni resultados nuevos de speedup o de latencia bajo carga.

## Ejecución por el equipo

```powershell
# Vista previa sin Docker: 63 ejecuciones previstas, seis calentamientos.
./scripts/benchmark.ps1 -Action Plan -Campaign g7-plan-01

# Smoke del entorno exclusivo, con datos sintéticos pequeños.
./scripts/benchmark.ps1 -Action Smoke -Campaign g7-smoke-01
./scripts/benchmark.ps1 -Action Stop -Campaign g7-smoke-01

# Pruebas del runner sin Docker; los resultados se marcan sintéticos.
./tests/benchmark/test-runner.ps1
```

No ejecutar una campaña real sobre la base de un smoke: usar otra campaña. `Run` identifica los cinco adaptadores ausentes y no los reemplaza por fixtures. Al incorporarse, los scripts reciben contexto/muestra/salida explícitos según el contrato.

## Estado por requisito del issue

| Requisito | Estado de esta entrega |
|---|---|
| Referencia/configuración/datos/entorno | Implementado: commit, diff hash, inventario de fuentes, checksums de originales, imágenes, Go/Docker/Compose y límites. El estado sucio del checkout se conserva sin atribuir cambios locales a un commit. |
| Verificar Docker Linux | Comprobado. El CLI de arranque había fallado; iniciar el ejecutable instalado de Docker Desktop permitió recuperar el motor sin reinstalar ni borrar datos. |
| Entorno separado de la demo | Implementado y smoke con comprobación de conservación. La infraestructura mide fixtures, no se declara cerrada una campaña real. |
| Contratos y configuración | Publicados y comprobados por tests; necesitan que cada responsable integre/valide su adaptador. |
| Runner y fallos | Implementados con fixtures, bloqueo, errores, timeout y validación. No se ocultan integraciones faltantes. |
| Integración de componentes reales | **Pendiente de #2–#5.** |
| Evidencia y retención | Manifestaciones compactas, stdout/stderr y ZIP exportable. Se conservan volúmenes y datos al detener; no hay limpieza destructiva automática. |
| Conservación de demo | Smoke comprueba MongoDB y archivos; la regresión final de producto pertenece al cierre integrado y a Vera. |
| Revisión/merge del PR | **Pendiente de aprobación independiente.** Esta entrega no cierra #1. |

## Dependencias concretas para la siguiente entrega

| Issue | Entrega que falta | Interfaz prevista |
|---|---|---|
| López #2 | Cargas nuevas L1/L4, equivalencia/conteos y métricas de ingesta | `scripts/benchmark-load.ps1` |
| Taco #3 | Fases de entrenamiento, candidatos SGD previos a selección y referencia/encoder verificables | Instrumentación usada por el adaptador de entrenamiento |
| Gerardo #4 | Campañas S/D1/D2/D4, colector de recursos y agregador | `benchmark-training.ps1`, `benchmark-resources.ps1`, `benchmark-summary.ps1` |
| Dragon #5 | Generador HTTP, preparación/retorno de Redis y métricas de intentos | `scripts/benchmark-api.ps1` |
| Vera | Auditoría/chequeo independiente e informe final | Issue por crear al confirmar su acceso |

Con el primer PR aprobado, los integrantes pueden actualizar sus ramas desde `main`, desarrollar contra este contrato y entregar sus PR por componente. Después Cueva integrará los adaptadores, comprobará un smoke conjunto, organizará campañas por turnos y actualizará el issue sin cerrarlo antes de satisfacer sus criterios.

## Verificación y evidencia

La campaña de desarrollo `cueva-infra-smoke-v1` pasó con 3 viajes, 192 ventanas, entrenamiento secuencial/distribuido, dos workers con 27 tareas cada uno y miss/hit de Redis. Se verificaron 12 archivos de datos/modelos/snapshots y, de forma independiente en MongoDB, el dataset/modelo activos y 1,348,665 viajes / 378,720 ventanas de la demo. Antes/después fueron idénticos; al terminar se retiraron únicamente los servicios del smoke.

Esta primera ejecución sirvió para verificar la base durante el desarrollo. Se repitió el smoke en la campaña **`cueva-infra-final-v1`** sobre el commit de implementación **`3fe56f6d789f961b0918d7f34e0f259598251866`**. Volvió a pasar y la demo permaneció intacta también al detener ambos entornos de pruebas. El checkout registra cambios locales previos del README; el inventario SHA-256 identifica las fuentes efectivas usadas.

| Verificación | Resultado y evidencia |
|---|---|
| Runner y fallos | **40 comprobaciones aprobadas**, todas con componentes controlados; [detalle](../bench/results/cueva-infra-final-v1/runner-tests.json). Incluye datos tipados, métricas inválidas, identificación/scope, contribución de workers, candidato SGD previo a selección, checksums de recursos, timeout, solapamiento y resumen incompleto. |
| Formato/sintaxis | Sintaxis PowerShell válida y `git diff --check` correcto. |
| Suite Go existente | `go vet ./...` y `go test -race -count=1 ./...` aprobados dentro de Docker, con integración MongoDB aislada. Salidas completas en el ZIP; [resumen](../bench/results/cueva-infra-final-v1/checks.json). |
| Smoke final | 3 viajes / 192 ventanas, ambos modos de entrenamiento, dos workers y 27 tareas por worker, predicción y miss/hit Redis; [resultado](../bench/results/cueva-infra-final-v1/smoke.json). |
| Preservación | [Antes/después del smoke](../bench/results/cueva-infra-final-v1/preservation-smoke.json) y [del apagado](../bench/results/cueva-infra-final-v1/preservation-stop.json): archivos y MongoDB observados sin cambios. |
| Precondiciones de campaña real | `Run -Campaign cueva-pending-check-v1` devuelve error esperado, estado **blocked** y cinco adaptadores ausentes; [manifiesto](../bench/results/cueva-pending-check-v1/manifest.json). Ninguna muestra se ejecutó. |
| Entorno | Docker Linux, 16 CPU lógicas / 7,197,335,552 bytes asignados, Compose 5.6.1, Go 1.27.2; [entorno, límites e imágenes](../bench/results/cueva-infra-final-v1/environment.json). Otras cargas estaban presentes: no son condiciones de benchmark de rendimiento. |

El [ZIP de evidencia compartible](../bench/evidence/cueva-infra-final-v1.zip) contiene 35 entradas de resultados/logs con su [SHA-256](../bench/evidence/cueva-infra-final-v1.zip.sha256): `dbe16b2975e58df6f767e83ba0786499cf484c3fb600c2b1cbbd5baf11b71832`. Se comprobó que no contiene el contexto privado, el archivo de credenciales ni los tres secretos de benchmark. Los datos/modelos grandes y credenciales permanecen locales. Ambos proyectos de benchmark quedaron detenidos, conservando volúmenes y evidencia; la demo sigue funcionando.

Ni el smoke ni los tests sintéticos se contabilizan como ensayos reales de las semanas 12–13. Los resultados no evalúan speedup, calidad predictiva nueva ni la meta de API bajo carga.

## Límites explícitos

- No hay implementación sustitutiva del trabajo asignado a los otros integrantes.
- Un esquema válido y checks declarados no sustituyen la auditoría de encoder, particiones, fórmulas ni calidad de mediciones; Vera contrastará esas evidencias.
- El mutex evita solapamiento de este runner en la sesión del host, pero no detiene procesos ajenos ni sincroniza otras computadoras. El entorno registra cuántos contenedores ajenos corren; el rendimiento real exige turnos y condiciones controladas.
- Los originales deben existir/verificar checksum antes de Prepare/Smoke; la descarga es el procedimiento del proyecto, fuera de medición.
- Volúmenes y credenciales permanecen locales al detener. El ZIP solo incluye salidas permitidas y redacta secretos conocidos; revisar el archivo antes de compartir.
- No se cierra la pregunta social, el mapa, la mejora predictiva ni el despliegue final de semanas posteriores.
