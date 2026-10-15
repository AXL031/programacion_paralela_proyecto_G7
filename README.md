# Programación paralela · Proyecto G7

**Demo técnica de las semanas 7 a 10 reproducida y verificada en esta computadora el 13 de octubre de 2026.** Proyecto 9 en Go con 1,348,665 viajes persistidos, cargador concurrente, maestro y dos trabajadores TCP, MongoDB, Redis, API REST con JWT, WebSocket y SPA React con telemetría. Pasaron formato, `go vet`, pruebas con detector de carreras e integración MongoDB, además del recorrido de navegador. La pregunta social actual tiene un alcance menor que la guía y el mapa y las comparativas de rendimiento siguen pendientes.

El cumplimiento de las 14 actividades de esas semanas está documentado en [SEMANA_7_10.md](docs/SEMANA_7_10.md). Las mediciones de escalabilidad, comparación final y despliegue en otra computadora corresponden a semanas posteriores.

La [auditoría del 13 de octubre](docs/AUDITORIA_SEMANA_10.md) contrasta el cronograma adjunto y la guía y registra el cierre operativo local. La [evidencia nueva](docs/VERIFICACION_LOCAL_SEMANA_10.json) conserva conteos independientes de MongoDB, runs, salud del clúster y resultados de los chequeos.

Para preparar esta copia, ejecuta `./scripts/prepare-local.ps1`. Cuando Docker Desktop esté instalado e iniciado con motor Linux, ejecuta `./scripts/prepare-local.ps1 -StartDemo`: reproduce la demo y ejecuta formato, `go vet` y pruebas con detector de carreras dentro de Docker.

## Inicio en Windows

Para uso diario, abre **Iniciar demo.cmd**: inicia Docker Desktop si hace falta, levanta el maestro y dos workers con los servicios, espera al modelo preparado y abre el navegador. Reutiliza imagenes, datos y modelo; no repite descarga, entrenamiento ni pruebas. Los accesos **Iniciar demo G7** y **Apagar demo G7** del escritorio apuntan a estos archivos.

Al terminar, abre **Apagar demo.cmd**: detiene y retira los contenedores del proyecto sin borrar el volumen de MongoDB ni los archivos de datos/modelos. Si no quedan otros contenedores funcionando, tambien cierra Docker Desktop y su motor Linux para liberar recursos. Cerrar solo la pestaña del navegador no apaga el sistema. Al volver a iniciar, entra con las credenciales locales.

Los comandos siguientes sirven para preparar o reconstruir la demo completa, no para el inicio diario.

Abre Docker Desktop con motor Linux y ejecuta desde la raíz:

```powershell
./scripts/demo.ps1
```

Descarga aproximadamente 50 MB de datos verificados, genera credenciales locales, construye los servicios, carga datos, entrena en ambos modos y verifica REST/JWT/WebSocket/Redis/telemetría. Con archivos ya descargados:

```powershell
./scripts/demo.ps1 -SkipDownload
```

Abre **http://127.0.0.1:3000**. Usuario por defecto: `demo`. La contraseña está en `DEMO_PASSWORD` del archivo local `.env`, generado por `scripts/init-env.ps1`. Los secretos no se muestran en los scripts ni se guardan en Git. Si cambias credenciales o claves, recrea los servicios para aplicar el cambio.

La sesión dura 30 minutos. La interfaz permite consultar zonas e intervalos, iniciar entrenamiento, ver CPU/RAM y pérdida en vivo, comparar resultados y explorar actividad por distrito. El navegador recibe predicciones y telemetría por WebSocket; REST sirve datos, control y respaldo de consultas. No necesitas instalar Node ni Go en el host: Docker compila React y Go.

Para reiniciar una instalación preparada:

```powershell
./scripts/init-env.ps1
docker compose up -d --scale worker=2 --wait
```

Puertos publicados: web 3000 y API 8080, solo en `127.0.0.1`. MongoDB, Redis, maestro HTTP/TCP y workers quedan dentro de la red de Compose. El control interno del maestro requiere un token separado. Configura `WEB_PORT` y `API_PORT` en `.env`; las comprobaciones resuelven los puertos de Compose.

Hay siete contenedores persistentes: MongoDB, Redis, API, web, maestro y dos trabajadores. Loader y trainer son trabajos separados. Un reinicio de API invalida las sesiones y exige iniciar sesión nuevamente.

## Datos y pregunta de impacto

Fuente: [NYC TLC Yellow Taxi](https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page), archivo de enero de 2024. La configuración principal selecciona del 1 al 15 de enero en hora de Nueva York, leyendo todo el archivo para filtrar por fecha.

| Medida | Resultado |
|---|---:|
| Filas de origen leídas | 2,964,624 |
| Viajes válidos persistidos | 1,348,665 |
| Rechazos dentro del período | 14,905 |
| Fuera del período | 1,601,054 |
| Zonas | 263 |
| Ventanas de 15 minutos | 378,720 |
| Ejemplos | 378,457 |
| Train / validación / test | 264,841 / 56,808 / 56,808 |

Pregunta: **¿Cómo anticipar la actividad de viajes registrada por zona e intervalo para apoyar la planificación del transporte?** La sección Impacto muestra conteos reales por distrito y límites de interpretación. Los viajes completados no permiten medir solicitudes rechazadas, oferta disponible ni desigualdad de acceso. El beneficio operativo propuesto todavía requiere validación con responsables de transporte.

La predicción estima `[origen, origen + 15 minutos)` usando el intervalo anterior y calendario conocido. El valor observado del objetivo se muestra para comparar la reproducción histórica, sin entrar al modelo. No se ofrecen fechas futuras sin historial.

`configs/quick.json` conserva la selección original de tres días; `configs/demo.json` es la selección ampliada. La carga anterior y sus artefactos se conservan. Cargar otra configuración cambia el dataset activo: hay que entrenar su modelo antes de consultarlo.

El loader lee CSV/Parquet por bloques, usa goroutines/channels acotados, valida datos, conserva rechazos por causa y escribe MongoDB por lotes. La carga completa se reutiliza sin duplicar viajes y verifica el checksum del snapshot. Las cargas parciales no se publican. Fuentes/checksums: `configs/sources.json`. Una interrupción abrupta del loader todavía requiere diagnóstico manual.

## Entrenamiento y publicación

`linear-count-v2` usa conteos normalizados, zona/día categóricos, hora cíclica y lag general y por zona. SGD con mini-batch/L2 y normalización ajustada solo en train. El maestro reparte índices del batch global, cada worker calcula su gradiente parcial y el maestro agrega por número de ejemplos antes de aplicar una única actualización. Los workers montan el snapshot compartido en solo lectura y mantienen una copia de los ejemplos; la partición del trabajo es lógica por tarea.

La mezcla con persistencia se elige usando validación. Si no mejora MAE sin empeorar RMSE, publica persistencia explícitamente. **En la muestra ampliada la validación eligió persistencia.** El candidato SGD sí se entrenó; no se presenta como mejora predictiva.

| Test ampliado | Publicado | Referencia |
|---|---:|---:|
| MAE | 1.086396 | 1.086396 |
| RMSE | 3.553259 | 3.553259 |

Los modos secuencial y distribuido produjeron los mismos parámetros publicados. Cada uno de los dos workers aportó 3,960 tareas. Tiempo funcional: 14.24 s secuencial, 18.64 s distribuido. No se ha demostrado speedup; el benchmark repetido corresponde a semanas posteriores.

```powershell
./scripts/train-demo.ps1
```

Cada ejecución crea versiones nuevas. Artefactos en `data/models/` y MongoDB, junto con historial y modelo activo. Un worker caído falla el entrenamiento y conserva el modelo anterior. Al reiniciar el maestro, trabajos interrumpidos quedan fallidos y los workers reconectan. La API cambia su modelo en memoria de forma atómica y sin interrumpir consultas. Reasignación/checkpoints son trabajo posterior.

## Contratos y autenticación

| Operación | Ruta |
|---|---|
| Salud pública | `GET /health/live`, `GET /health/ready` |
| Sesión | `POST /api/v1/auth/login`, `GET /api/v1/auth/session`, `POST /api/v1/auth/logout` |
| Datos | `GET /api/v1/datasets/current`, `/zones`, `/observations`, `/impact` |
| Predicción | `GET /api/v1/models/current`, `POST /api/v1/predictions` |
| Clúster | `GET /api/v1/cluster` |
| Entrenamiento | `GET /api/v1/training-config`, `POST /api/v1/training-runs`, `GET /api/v1/training-runs/{id}` |
| Eventos y predicción | `GET /api/v1/events` con upgrade WebSocket |

Todas las rutas de proyecto requieren JWT válido. El navegador usa cookie HttpOnly y SameSite Strict, sin almacenar tokens en localStorage. Los scripts usan Bearer. Algoritmo HS256 fijado, firma/emisor/audiencia/rol/expiración validados, contraseña comprobada mediante bcrypt y revocación al salir. Cookies de escritura y WebSocket validan Origin. Es una demo local HTTP; para HTTPS puede activarse cookie Secure. No hay registro público ni administración multiusuario en este alcance.

Ejemplo autenticado, usando las credenciales locales sin imprimirlas:

```powershell
. ./scripts/session.ps1
$headers = Get-DemoAuthorization 'http://127.0.0.1:3000'
$dataset = Invoke-RestMethod http://127.0.0.1:3000/api/v1/datasets/current -Headers $headers
$consulta = @{
    dataset_id = $dataset.dataset_id
    zone_id = 161
    forecast_origin = '2024-01-16T01:45:00Z' # 15 enero, 20:45 Nueva York
    horizon_minutes = 15
} | ConvertTo-Json
Invoke-RestMethod http://127.0.0.1:3000/api/v1/predictions -Method Post -ContentType application/json -Body $consulta -Headers $headers
```

WebSocket envía snapshots cada segundo con clúster, entrenamiento, pérdida y modelo; recibe `watch` y `predict` con ID de correlación. JWT vencido/revocado cierra el canal. El cliente reconecta con sesión válida y puede usar REST para consultar mientras se recupera el canal. Contrato completo en [DATA_CONTRACT.md](docs/DATA_CONTRACT.md).

## Telemetría y Redis

CPU es consumo del **proceso Go**, con 100% equivalente a un núcleo; RAM es RSS del proceso en MiB. El maestro mide cada segundo y los workers remiten su muestra por heartbeat cada dos segundos. Muestras antiguas se muestran como no disponibles. La pérdida visible es el objetivo normalizado del batch, distinta de MAE/RMSE de evaluación. No se presentan valores simulados.

Redis usa claves por versión/checksum/intento/zona/origen/horizonte, con TTL de una hora. Los accesos tienen límite de 30 ms sin reintentos. Una caída de Redis omite la escritura y calcula en memoria. Readiness requiere MongoDB e informa Redis como opcional; la disponibilidad del modelo se consulta por separado.

## Verificación

```powershell
docker compose --profile tools run --rm dev go test -race -count=1 ./...
docker compose --profile tools run --rm dev go vet ./...
./scripts/check-demo.ps1
./scripts/check-weeks-7-10.ps1
```

Pruebas de carga idempotente, gradiente, equivalencia TCP, duplicados/timeout, ausencia de fuga temporal, caché versionada, cambio concurrente de modelo, JWT inválidos/revocación/origen, WebSocket real y recursos del proceso. MongoDB de integración usa una base temporal propia.

`check-weeks-7-10.ps1` verifica más de un millón de registros, acceso anónimo rechazado, JWT modificado rechazado, predicción WebSocket, recursos del maestro/workers, conteos de impacto y revocación tras logout. Resultados locales en `data/weeks-7-10-check.json`; evidencia resumida en `docs/SEMANA_7_10_VERIFICACION.json`. Los archivos de `data/` se reemplazan al repetir comprobaciones.

## Estructura

```text
cmd/                 loader, trainer, master, worker, api y web
internal/loader      lectores y pipeline concurrente
internal/features    agregados y snapshot temporal
internal/ml          normalización, SGD, selección y evaluación
internal/training    ejecución y artefactos
internal/cluster     protocolo TCP, maestro y workers
internal/telemetry   CPU y memoria real del proceso
internal/storage     MongoDB y archivos para fixtures
internal/api         JWT, REST, WebSocket, inferencia y caché
web/src              SPA React
web/dist             compilación generada y embebida en Go
configs/             fuentes, demo ampliada, muestra rápida y entrenamiento
deploy/              imágenes de servicios Go y build de React
scripts/             inicio, sesiones, entrenamiento y comprobaciones
tests/               fixtures e integración
docs/                plan, contratos y evidencia
data/                datos y resultados ignorados por Git
```

La construcción React usa dependencias fijadas y lockfile, sin CDN en ejecución. CI incluye build React y checks Go; su ejecución remota no se ha afirmado ni probado en esta sesión.

## Continuación y parada

Pendientes de semanas posteriores: benchmarks repetidos de carga/entrenamiento, cuatro workers reales, escalabilidad y uso de recursos, cuadro final de speedup, despliegue limpio y otra computadora. El plan general también contempla mapa y recuperación con checkpoints.

```powershell
docker compose down
```

Conserva MongoDB. No agregues `--volumes` para mantener datos. Conserva también `data/processed` para reentrenar. Reiniciar API exige iniciar sesión de nuevo.
