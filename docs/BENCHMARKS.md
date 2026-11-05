# Benchmarks integrados

Dragon implementa `cmd/benchmark-api` y `scripts/benchmark-api.ps1` con la interfaz `ContextPath/SamplePath/OutputPath`. Consume el entorno aislado y los helpers de Cueva; no opera sobre la demo. Se retiraron los scripts duplicados de preflight, carga y entrenamiento: esas operaciones pertenecen al runner y a los componentes de López/Gerardo.

## Reproducción

Sobre la integración de `cueva` y `dragon`, con los datos reales descargados:

```powershell
./scripts/benchmark.ps1 -Action Plan -Campaign g7-final-01
./scripts/benchmark.ps1 -Action Prepare -Campaign g7-final-01
./scripts/benchmark.ps1 -Action Run -Campaign g7-final-01
./scripts/benchmark.ps1 -Action Stop -Campaign g7-final-01
./scripts/benchmark.ps1 -Action Export -Campaign g7-final-01
```

El runner congela fuentes/configuración. Cambiar código exige otra campaña. No reutilizar una campaña de smoke para declarar rendimiento real.

## API

- Tres estados Redis × concurrencia 1/10/25 × tres pasadas × 1.000 solicitudes: 27.000 intentos medidos. Solo se vacía/detiene Redis del proyecto aislado y se restaura incluso al fallar.
- Cliente Go de bucle cerrado, conexiones persistentes y solicitudes en vuelo acotadas. Tiempo desde antes de enviar hasta leer completamente la respuesta. Login, smoke y precalentamiento quedan fuera.
- Frío: claves únicas en Redis vacío. Caliente: precalentamiento de todo el inventario. No disponible: parada observada por readiness y fallback sin hits.
- Validación HTTP/JSON/dataset/modelo/zona/origen/horizonte/valores/cache_hit. Se conservan todos los intentos, errores y timeouts; los errores permanecen en percentiles.
- p50/p95/p99/máximo por nearest rank, throughput total y de éxitos, latencias de errores y proporción bajo 100 ms. Se informa cumplimiento/incumplimiento por caso.
- JWT y contraseñas no aparecen en argumentos ni reportes. Credenciales exclusivas de benchmark y logout al finalizar.
- REST directo en la red aislada. El ensayo proxy se registra aparte, sin mezclar métricas.

`go test -race -count=1 ./cmd/benchmark-api` cubre concurrencia, identidad, caché inesperada, HTTP no-200, JSON inválido, campos ausentes, timeout y agregados conocidos. Esas pruebas no sustituyen campañas reales.

Contratos: [benchmark-v1](CONTRATO_BENCHMARK.md), [carga](BENCHMARK_CARGA.md), [entrenamiento](BENCHMARK_ENTRENAMIENTO.md), [recursos](BENCHMARK_ESCALABILIDAD.md).
