# Benchmark de API — Dragon

Implementación en `dragon`: cliente `cmd/benchmark-api`, adaptador `scripts/benchmark-api.ps1` y ensayo separado `scripts/benchmark-proxy.ps1`. El runner, los contratos y el colector compartido proceden de la integración de `cueva`.

La actualización de captura de recursos de `2441322` se integra mediante el colector común `benchmark-resources.ps1` y sus módulos `benchmark/resources.psm1` y `benchmark/statistics.psm1`: conservan CPU/RSS del proceso y CPU/memoria de contenedor por separado, timestamps, cobertura, faltantes y checksums. Se retiran los módulos/scripts duplicados que no implementaban el contrato o usaban la demo. El commit original se conserva como padre del merge; no se fuerza la rama remota.

## Procedimiento

El cliente Go usa un pool acotado y conexiones persistentes. Cada intento conserva fecha UTC, estado HTTP, tiempo desde antes de enviar hasta leer completamente la respuesta, caché observada, timeout y error. Valida JSON completo, dataset/modelo, zona/origen/horizonte y valores numéricos. Los JWT y contraseñas no se guardan en logs ni en argumentos.

| Estado Redis | Preparación | Comprobación |
|---|---|---|
| Frío | Vaciar exclusivamente Redis de la campaña; claves válidas únicas | Todas las respuestas medidas son miss |
| Caliente | Precalentar y verificar hits en las 1.000 claves fuera de medición, con hasta cinco pasadas de preparación | Todas las respuestas medidas son hit |
| No disponible | Detener Redis aislado y comprobar readiness | Predicción fallback sin hits y restauración posterior |

Matriz: estados anteriores × concurrencia 1/10/25 × tres pasadas × 1.000 solicitudes = **27.000 intentos medidos**. Login, smoke y precalentamiento se excluyen. No se agregan las peticiones por proxy a esta matriz.

Los percentiles p50/p95/p99 y máximo usan nearest rank e incluyen las latencias de intentos fallidos; se publican errores/timeouts, throughput total y de éxitos y proporción bajo 100 ms. La meta operativa es p95 <100 ms y cero errores inesperados en cada pasada. Una meta incumplida permanece visible y no se convierte en éxito por haber ejecutado el script.

## Comandos

```powershell
./scripts/benchmark.ps1 -Action Prepare -Campaign g7-new-api-01
./scripts/benchmark.ps1 -Action Run -Campaign g7-new-api-01
./scripts/benchmark-proxy.ps1 -Campaign g7-new-api-01
./scripts/benchmark.ps1 -Action Stop -Campaign g7-new-api-01
./scripts/benchmark.ps1 -Action Export -Campaign g7-new-api-01
```

La campaña completa prepara carga y modelo antes de medir API. `benchmark-api.ps1` no se invoca sin el contexto validado. La pasada proxy es autenticada y solo consulta el modelo de la demo; no modifica datos ni entrenamiento y guarda un reporte independiente. Usa `cache=observed`: registra hits y misses reales sin vaciar ni detener Redis de la demo. Los tres escenarios controlados se exigen exclusivamente en la matriz aislada.

## Pruebas y resultados

`go test -race -count=1 ./cmd/benchmark-api` verifica concurrencia, identidades, caché inesperada, HTTP no-200, JSON inválido, campos ausentes, timeout y estadísticas conocidas con servidores controlados. No sustituye a los ensayos reales.

Los resultados por escenario y la evidencia real se consolidan en el [cierre técnico de la integración](CIERRE_DESARROLLO_11_13.md). Los errores de pilotos/campañas anteriores se conservan y se distinguen de las campañas completas. Vera realiza la auditoría independiente en #8.
