# Estado verificado de los pasos 1 a 3

Revisión: 12 de octubre de 2026. Implementación local, todavía sin commit o publicación externa.

## Resultado

| Paso del plan | Estado | Evidencia |
|---|---|---|
| 1. Base ejecutable | Completado | MongoDB, Redis y API construidos y ejecutándose en Compose; tres servicios healthy. |
| 2. Datos y objetivo | Completado | Archivo TLC enero de 2024 y catálogo descargados; fuentes y SHA-256 fijados; selección continua de tres días y alcance documentados. |
| 3. Loader y features | Completado | Ingesta real, validación concurrente, persistencia por lotes, agregados, snapshot, recarga sin duplicados y consulta HTTP comprobados. |

El motor Docker está accesible. Se incorporó Go portátil dentro de `.tools/` para verificar el código sin modificar una instalación global; esa carpeta está ignorada. El entorno Docker usa Go 1.27.2, MongoDB 8.0.16 y Redis 7.4.7.

Actualización posterior: maestro, trabajadores TCP, SGD y artefactos del modelo ya están implementados en los [pasos 4 y 5](PASOS_4_5.md). Este documento conserva las evidencias de la etapa de carga. JWT, WebSocket, API de predicciones y pantalla siguen pendientes.

## Carga real ejecutada

Fuente: NYC TLC Yellow Taxi, enero de 2024, Parquet. Tamaño del archivo: 49.961.641 bytes. Se consumió el archivo completo y se seleccionaron recogidas entre el inicio del 1 y el inicio del 4 de enero de 2024, en `America/New_York`.

Dataset: `ds-c1eb3326f0344d814705ba2c39bd8d23`.

Intento publicado: `23fbbd346b61a28633578424`.

| Contador | Resultado |
|---|---:|
| Filas leídas del archivo | 2.964.624 |
| Viajes válidos de la selección | 235.761 |
| Viajes persistidos | 235.761 |
| Rechazos | 3.198 |
| Filas fuera del período | 2.725.665 |
| Zonas del catálogo usadas | 263 |
| Ventanas de 15 minutos | 75.744 |
| Ejemplos temporales | 75.481 |
| Ejemplos train | 52.600 |
| Ejemplos validation | 11.309 |
| Ejemplos test | 11.572 |

Rechazos: 3.183 por zona no válida para el análisis, 13 por duración no positiva y 2 por duración superior a 24 horas. Las cifras satisfacen `read = accepted + rejected + outside_period` y `persisted = accepted`. Una consulta independiente a MongoDB verificó que la suma de los conteos de todas las ventanas es 235.761.

Una ejecución completa del cargador, incluyendo lectura/filtro, persistencia y exportación, tomó **28,53 segundos** y registró aproximadamente 103.911 filas de origen por segundo. Es una observación de esta máquina, sin comparativa controlada ni repeticiones; no demuestra speedup ni constituye un benchmark final. Tampoco significa haber persistido más de un millón de registros: el dataset de demo conserva 235.761 viajes.

## Snapshot disponible

Ruta del snapshot generado:

```text
data/processed/ds-c1eb3326f0344d814705ba2c39bd8d23/23fbbd346b61a28633578424/features.ndjson
```

SHA-256 comprobado contra el archivo local:

```text
00888161998451f355370bc688b380b216ce85f6869404066aab9576d672758c
```

Features sin normalizar: zona categórica, hora seno/coseno, día de semana categórico, fin de semana y conteo del intervalo anterior. El target es el conteo del intervalo siguiente al histórico usado. Cortes temporales exactos: train termina en `2024-01-03T07:15:00Z`, validation en `2024-01-03T18:00:00Z`; test llega hasta el final de la selección.

También se generó `windows.ndjson` en esa carpeta. Los datos grandes están fuera de Git. MongoDB conserva el manifiesto completo para recuperar rutas, configuración, métricas y checksums.

## Verificaciones realizadas

- Pruebas Go unitarias y de integración con MongoDB: pasaron.
- Detector de carreras con `go test -race -count=1 ./...` dentro de Docker: pasó, incluyendo integración con una base temporal propia.
- Revisión estática con `go vet ./...`: pasó.
- Lectura CSV con comillas, coma y campo multilínea: verificada con fixture identificado como sintético.
- Lectura Parquet, valores nulos y conversión de hora local TLC a UTC: verificadas.
- Carga del mismo fixture con 1 y 4 goroutines: misma identidad, mismos conteos y mismo SHA-256 de features.
- Fallo de persistencia inyectado y CSV estructuralmente inválido: no publican datos parciales.
- Horas locales ambiguas/inexistentes y checksums alterados: rechazados.
- Recarga del dataset real: reutiliza el mismo intento completo; se mantienen 235.761 viajes y 75.744 ventanas, sin una nueva inserción.
- Reinicio de MongoDB, Redis y API: permanecen el mismo dataset, intento y conteos; servicios vuelven a healthy.
- Consulta real de zona 161 durante el 1 de enero: 96 ventanas y suma de 3.009 viajes aceptados.
- Fuentes, datos generados y cachés excluidos correctamente de Git; solo `data/.gitkeep` permanece versionable dentro de `data/`.

La workflow de GitHub está preparada, pero no se ejecutó remotamente porque no se publicó el cambio. La persistencia se comprobó reiniciando los servicios locales; no se borraron volúmenes.

## Uso inmediato

Los servicios se dejan levantados. Consultas locales:

- Salud: `http://127.0.0.1:8080/health/ready`.
- Dataset procesado: `http://127.0.0.1:8080/api/v1/datasets/current`.
- Zonas: `http://127.0.0.1:8080/api/v1/zones`.

Para reproducir:

```powershell
./scripts/first-steps.ps1
```

Para reutilizar los archivos descargados:

```powershell
./scripts/first-steps.ps1 -SkipDownload
```

La salida del loader se guarda como JSON en `data/demo-load.json`; logs de construcción se mantienen separados de ese resultado.

## Próximo paso del plan

El entrenamiento secuencial y su distribución por TCP ya se completaron en la etapa siguiente. Ahora corresponde conectar la API de predicciones y la pantalla, siguiendo los pasos 6 y 7.

Para la entrega final quedan pendientes el volumen completo persistido, los experimentos 1/2/4 de entrenamiento, latencia de predicciones y los servicios de interfaz/autenticación/eventos del plan.
