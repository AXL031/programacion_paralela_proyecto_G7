# Contrato de datos implementado

## Fuente y alcance

Yellow Taxi enero de 2024 de NYC TLC, Parquet. Selección principal: recogidas desde `2024-01-01T00:00:00-05:00` hasta `2024-01-16T00:00:00-05:00`, final exclusivo. Son 1,348,665 viajes válidos. `configs/quick.json` conserva los tres días originales; `configs/demo.json` utiliza quince días. Fuente y checksums: `configs/sources.json`.

Se procesa el archivo completo y se filtra por fecha; no se toman las primeras N filas. El conteo representa registros completados aceptados por las reglas del proyecto; no solicitudes totales ni demanda no cubierta.

## Identidad y publicación

`dataset_id` es una huella de archivo, catálogo, período, zona horaria, formato, ventana y versión de procesamiento. Concurrencia y tamaño de lote no cambian esa identidad. `load_id` identifica un intento; los IDs de viajes combinan intento y ordinal de origen.

MongoDB contiene `datasets`, `trips`, `windows` y `settings`. Una carga empieza en `loading`. La API lee un dataset `complete` mediante `settings.current_dataset`. `failed` permite otro intento; un proceso activo no puede ser sobrescrito. Datos parciales no son visibles por los endpoints.

La recarga comprueba el checksum del snapshot y reutiliza el intento completo. El backend de archivos reproduce esa semántica sin MongoDB. Un proceso terminado abruptamente puede dejar un bloqueo; su recuperación requiere diagnóstico manual en esta etapa.

## Validación y contabilidad

Entrada obligatoria: `tpep_pickup_datetime`, `tpep_dropoff_datetime`, `PULocationID`, `DOLocationID`, `trip_distance`. Campo ausente del schema falla la carga; valor nulo/inválido se cuenta como rechazo. Un CSV estructuralmente ilegible falla para evitar inventar límites de registros.

Reglas: fechas interpretables, recogida dentro del período, zonas del catálogo entre 1 y 263, duración positiva de hasta 24 horas y distancia finita no negativa. Se asigna un motivo por fila según el orden de validación. Filas fuera del período tienen contador independiente.

```text
read = accepted + rejected + outside_period
persisted = accepted                    # en carga completa
sum(observed_trips en windows) = accepted
```

Las horas locales de TLC se convierten a UTC después de validar su zona. Horas bare ambiguas/inexistentes por cambios de horario se rechazan; un offset explícito puede desambiguar el caso en CSV.

## Ventanas y features

`Window`: dataset/intento, zona, inicio UTC, conteo y cobertura `accepted_records_in_source_file`. Se emite la rejilla de zonas válidas y ventanas de la selección. Un cero significa ausencia de registros aceptados en esa celda; no garantiza cobertura completa de la ciudad.

`Example`: zona categórica, `forecast_origin`, `target_start`, seno/coseno de hora local, día de semana categórico, fin de semana, `lag1_count`, `target_count`, split temporal. El origen es el límite anterior al intervalo objetivo: se predice `[origin, origin + 15 minutos)` usando el lag de `[origin - 15 minutos, origin)`. Se omite la primera ventana por falta de lag dentro de la selección.

Los splits usan cortes al 70% y 85% del período. Las filas quedan ordenadas por tiempo/zona y la terminación desordenada de goroutines no cambia su checksum. El snapshot mantiene features sin normalizar; el normalizador entrenado se guarda dentro del artefacto del modelo de los [pasos 4 y 5](PASOS_4_5.md). El snapshot registra versión `raw-counts-v1`, esquema, checksum, ejemplos por split y cortes exactos.

## Límites iniciales

Hasta 64 trabajadores, bloques de 65.536 filas y lotes de 10.000; producto trabajadores/bloque hasta 1.048.576. Hasta 2.000.000 ventanas por carga; dividir períodos mayores. Canales acotados y escritor único. La memoria depende del pool y de claves zona/ventana, no de conservar todos los viajes.

## HTTP disponible

- `GET /health/live`: proceso vivo.
- `GET /health/ready`: MongoDB obligatorio; Redis opcional. Su caída se informa y no devuelve 503 por sí sola. No sustituye `models/current.ready`.
- `GET /api/v1/datasets/current`: manifiesto completo activo, 404 si no hay carga.
- `GET /api/v1/zones`: catálogo del dataset activo.
- `GET /api/v1/observations`: `zone_id`, `start`, `end` RFC3339 con offset; rango de hasta 24 horas dentro del período.

Rangos inclusivos al inicio y exclusivos al final. Se devuelven ventanas cuyo inicio pertenece al rango.

- `GET /api/v1/models/current`: disponibilidad, versión, dataset, métricas, selección y orígenes válidos.
- `POST /api/v1/predictions`: dataset, zona, origen RFC3339 con offset y horizonte de 15 minutos. Devuelve predicción, lag, observación retrospectiva, versión, split, caché y latencia interna.
- `GET /api/v1/cluster`: trabajadores y entrenamiento activo del maestro.
- `GET /api/v1/training-config`: configuración inicial para la demo.
- `POST /api/v1/training-runs`: configuración validada; retorna un ID sin esperar el entrenamiento.
- `GET /api/v1/training-runs/{id}`: estado/progreso o resultado persistido.
- `GET /api/v1/impact`: pregunta, límites y conteos por distrito del modelo/dataset activos.

La API acepta un solo objeto JSON de hasta 8 KiB, rechaza campos desconocidos, zonas/orígenes/horizontes inválidos con 400, dataset incompatible con 409 y falta de modelo con 503. No acepta horas fuera de la rejilla ni fechas futuras arbitrarias.

La inferencia usa exclusivamente el intervalo anterior y calendario conocido. `actual_observed_trips` se incluye para comparar el histórico; no entra al modelo. La normalización de features y target se ajusta únicamente con train. La selección de mezcla usa validación y nunca test. Evidencia en [PASOS_6_7.md](PASOS_6_7.md).

Cada proceso API mantiene una copia inmutable del modelo y los conteos. Refresca cada dos segundos y cambia el conjunto activo de forma atómica después de validar identidad, checksum y rejilla completa. Si falla el refresco conserva la última copia válida. Redis tiene claves por versión/checksum/intento/zona/origen/horizonte y TTL de una hora; un fallo de lectura omite la escritura y calcula en memoria. MongoDB sigue siendo el almacén persistente.

## JWT y sesión

Todas las rutas `/api/v1/` salvo login requieren sesión activa. Salud sigue pública. `POST /api/v1/auth/login` acepta `username` y `password`; retorna usuario, rol, `access_token`, `token_type` Bearer y `expires_at`, y establece cookie `pulso_session` HttpOnly/SameSite Strict con path `/api/`. `GET /api/v1/auth/session` comprueba sesión; `POST /api/v1/auth/logout` revoca su identificador y elimina la cookie.

HS256 fijado, emisor `pulso-api`, audiencia `pulso-web`, rol `operator`, sujeto del operador configurado, expiración obligatoria de 30 minutos. Contraseña comprobada mediante bcrypt; clave y credenciales proceden de `.env`. Firma/algoritmo/fechas/emisor/audiencia/rol inválidos o sesión revocada: 401. Origen incorrecto en login, escrituras con cookie o WebSocket: 403. Diez intentos de login por dirección/minuto; exceso: 429. Hasta 128 sesiones activas en la API de demo. Al reiniciar API se invalidan.

Bearer permite clientes y scripts. El navegador utiliza cookie, sin localStorage ni tokens en la URL. Para escrituras con cookie se exige el Origin configurado. La demo local usa HTTP en loopback; `AUTH_SECURE_COOKIE=true` se aplica al ejecutar detrás de HTTPS. La configuración actual tiene un operador local, sin registro público.

El maestro HTTP es interno y exige `MASTER_API_TOKEN` para control/consulta; solo salud está exenta. API y trainer pasan ese token, separado del JWT de usuario. No se publica el puerto del maestro al host.

## WebSocket

`GET /api/v1/events`: upgrade autenticado con la misma sesión/Bearer y Origin exactamente igual a la web. El token no se envía como query parameter. Mensajes JSON hasta 8 KiB. El canal de lectura tiene cola acotada y una única goroutine escribe; máximo de 32 conexiones y timeout de escritura de dos segundos. Al expirar o revocar sesión cierra con 1008.

Eventos recibidos:

```json
{"type":"watch","run_id":"run-77d7b266c651bbcd31a945e7"}
```

```json
{"type":"predict","request_id":"consulta-1","request":{"dataset_id":"ds-f16643c248cc24d26b992f45598dd3e8","zone_id":161,"forecast_origin":"2024-01-16T01:45:00Z","horizon_minutes":15}}
```

`snapshot`, emitido cada segundo: `sequence`, `at`, `cluster_available`, `cluster`, `run` y `model`. Run puede ser null si no se sigue un trabajo; al finalizar sigue informándose en el canal que lo observaba. Modelo incluye identidad, selección y evaluación. Si el coordinador falla, clúster no disponible; el modelo en memoria puede seguir consultándose.

Respuesta `prediction`: `request_id` y `prediction` con el mismo contrato REST, o `error`. `watch` mantiene seguimiento de progreso/finalización. Evento no reconocido retorna `error`. La desconexión no cancela entrenamientos; el cliente puede reconectar, volver a observar el run y consultar por REST.

## Métricas del clúster

`cluster.master` y cada `workers[].telemetry` contienen `sampled_at`, `cpu_percent`, `rss_bytes`, `heap_bytes` y `available`. CPU es consumo del proceso Go dividido por tiempo transcurrido, 100% equivale a un núcleo. RSS se mide en `/proc/self/status` dentro del despliegue Linux. No representa toda la memoria del host ni sustituye un benchmark de contenedores.

Maestro y workers toman muestras cada segundo; los workers envían por heartbeat cada dos segundos. El panel considera antigua una muestra de más de siete segundos y muestra ausencia en lugar de cero. En plataformas no Linux la memoria residente/CPU no se afirman disponibles.

El progreso contiene `objective_loss`, `epoch`, `step` y `total_steps`. La curva visible muestra muestras del objetivo normalizado de entrenamiento por batch. `log_loss`, MAE y RMSE son evaluaciones separadas y no se etiquetan como objetivo actual.
