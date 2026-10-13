# Correcciones y pasos 6 y 7

Verificación local: 12 de octubre de 2026. Cambios sin commit ni publicación externa.

Evidencia histórica del primer corte de tres días y frontend sin framework. La implementación actual amplía datos y agrega React, JWT, WebSocket y telemetría: [SEMANA_7_10.md](SEMANA_7_10.md). Sus métricas y requisitos sustituyen el estado actual descrito aquí; esta evidencia se conserva para comparar.

## Resultado

Paso 6: API de inferencia real, modelo en memoria, caché versionada, validación estricta y control asíncrono del entrenamiento. Paso 7: pantalla usable en español con formulario, gráfico, métricas, dos trabajadores, progreso y entrenamiento. Inicio reproducible mediante `scripts/demo.ps1`.

Siete contenedores: MongoDB, Redis, API, web, maestro y dos trabajadores. La web en `http://127.0.0.1:3000` consulta mediante proxy a la API. Las bases no publican puertos al host.

Resumen de evidencia conservado en [P0_VERIFICACION.json](P0_VERIFICACION.json). Los archivos de `data/` son resultados locales y pueden reemplazarse al repetir la demo.

## Modelo corregido

El primer modelo sobre logaritmos empeoraba frente a persistencia. `linear-count-v2` usa target y lag normalizados en escala de conteos y agrega una interacción de lag por zona: 538 parámetros para 263 zonas. El bias no recibe L2. Target, features y vocabulario se ajustan únicamente con train.

Se compararon configuraciones usando validación temporal y se fijaron 120 épocas, batch global 8192, learning rate 0.2, L2 0.00001 y semilla 42. Después de SGD se comparan mezclas con persistencia de 0.1, 0.25, 0.5, 0.75 y 1. Se selecciona la menor MAE que no empeore RMSE en validación; si ninguna mejora, se publica explícitamente persistencia. En esta muestra: `validated_sgd`, mezcla 0.5. Test no participa en ajuste ni selección.

| Split / métrica | Publicado | Persistencia |
|---|---:|---:|
| Validación MAE | 0.820577 | 0.821823 |
| Validación RMSE | 2.472268 | 2.495340 |
| Test MAE | 1.229382 | 1.238420 |
| Test RMSE | 3.623625 | 3.695189 |

La mejora es pequeña, evaluada en tres días de Yellow Taxi. No demuestra generalización a otros meses ni predicción de demanda no atendida. Se mantiene compatibilidad de lectura con `linear-log-count-v1`. El progreso informa `objective_loss`; `log_loss` es una métrica separada de evaluación.

Secuencial `run-f175d4034202390245b4604d` y distribuido `run-429dc0f03208b18340ac740d`: diferencia máxima de pesos `4.163336342344337e-17` frente a tolerancia `1e-9`. Dos trabajadores distintos procesaron 840 tareas cada uno. Entrenamiento: 2.942 s secuencial y 3.818 s distribuido. No hay evidencia de aceleración. Resultados completos en `data/training-comparison.json`; repetir crea nuevos IDs y tiempos.

## Clúster y recuperación

El caché de filas evita volver a interpretar NDJSON en cada trabajo. Se verifican los bytes SHA-256 antes de reutilizarlas; una prueba modifica el archivo después de cachearlo y exige rechazo. El maestro informa `active_run`, acepta un único objeto JSON y conserva un solo entrenamiento activo.

Al arrancar, el maestro marca fallidos los trabajos distribuidos que quedaron en cola/preparación/ejecución. Esto presupone un único maestro, como en Compose. Se reinició realmente durante un trabajo: quedó fallido, se conservó el modelo anterior y reconectaron dos workers. Evidencia en `data/master-recovery-check.json`.

No reasigna tareas ni reanuda épocas; esas funciones quedan en el paso 9. Los fallos y límites TCP previos siguen verificados por pruebas de duplicados, timeout y equivalencia.

## Inferencia y caché

La API valida modelo/dataset/checksum, carga una rejilla completa de conteos y publica una referencia inmutable de forma atómica. Refresca cada dos segundos y reutiliza la rejilla si el dataset no cambió. Un refresco fallido conserva la última versión válida. Consultar y entrenar no comparten pesos mutables.

La inferencia construye features temporales equivalentes al entrenamiento: zona, hora local cíclica, día/fin de semana y conteo anterior. La observación objetivo se devuelve para comparar el histórico; una prueba con target distinto demuestra que no entra al modelo.

Redis usa claves por versión/checksum/intento/zona/origen/horizonte, TTL de una hora, contextos de 30 ms y cero reintentos. Si falla la lectura, omite escribir y calcula en memoria. Valida respuestas cacheadas antes de usarlas. Readiness informa Redis como opcional y requiere MongoDB.

Se detuvo realmente Redis: la predicción conservó versión y resultado, con 31.17 ms de latencia interna, y el servicio se restauró. Evidencia en `data/redis-fallback-check.json`. La copia en memoria también permite seguir prediciendo cuando falla el refresco; las operaciones persistentes y lectura de datos siguen necesitando MongoDB.

Contrato completo en [DATA_CONTRACT.md](DATA_CONTRACT.md). Ejemplo:

```json
{
  "dataset_id": "ds-c1eb3326f0344d814705ba2c39bd8d23",
  "zone_id": 161,
  "forecast_origin": "2024-01-04T01:45:00Z",
  "horizon_minutes": 15
}
```

La versión verificada produjo 66.971529 viajes estimados, 68 anteriores y 60 observados. Es el 3 de enero, 20:45 de Nueva York.

## Guion de presentación

1. Ejecutar `./scripts/demo.ps1`; agregar `-SkipDownload` si los archivos ya están descargados.
2. Abrir `http://127.0.0.1:3000` y mostrar 235,761 viajes, 263 zonas y dos trabajadores.
3. Consultar Midtown Center o Midtown East en el 3 de enero. Mostrar estimación, lag, observación, gráfico y versión.
4. Pulsar **Entrenar modelo** con dos workers: progreso por polling cada dos segundos e indicadores de cálculo.
5. Consultar durante el entrenamiento. El modelo anterior sigue disponible; después se activa la nueva versión y actualiza la consulta.
6. Comparar MAE/RMSE y explicar el alcance de la reproducción histórica.

El navegador verificó cambio de zona/hora, cálculo real, progreso al 89%, consulta simultánea y finalización al 100% con activación automática de una versión nueva, sin errores de consola. La pantalla reintenta si falta el dataset y permite recuperar el control del clúster. La revisión responsive incluye móvil y escritorio; en móvil no se detectó desbordamiento horizontal y el gráfico adapta sus etiquetas al ancho disponible.

## Pruebas y mediciones

```powershell
docker compose --profile tools run --rm dev go test -race -count=1 ./...
docker compose --profile tools run --rm dev go vet ./...
./scripts/check-demo.ps1
```

La suite añade inferencia durante cambio concurrente de modelo, ausencia de fuga del target, caché por versión y cache offline, múltiples objetos JSON, histórico inválido, conservación ante refresco fallido, selección sin test y checksum después de cachear.

Una comprobación de 200 solicitudes secuenciales HTTP por el proxy web dio p95 19.65 ms en primera pasada y 15.94 ms en segunda, con 100 aciertos de caché. La primera incluía claves nuevas; la segunda repitió las consultas. Es un chequeo local desde PowerShell, no un benchmark de carga ni evidencia universal de p95 inferior a 100 ms. Cada ejecución conserva sus propios valores en `data/api-check.json`.

## Continuación

El corte P0 está cumplido. Sigue ampliar a más de un millón de viajes válidos y probar cuatro workers reales; después reasignación/checkpoints, mapa, JWT, WebSocket, benchmarks y entrega final. Redis y cambio atómico de modelo ya se adelantaron, pero no cierran por sí solos los pasos 9 y 10.
