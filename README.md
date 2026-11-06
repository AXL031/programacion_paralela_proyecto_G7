# Programación paralela · Proyecto G7

**Demo técnica de las semanas 7 a 10 reproducida y verificada en esta computadora el 13 de octubre de 2026.** Proyecto 9 en Go con 1,348,665 viajes persistidos, cargador concurrente, maestro y dos trabajadores TCP, MongoDB, Redis, API REST con JWT, WebSocket y SPA React con telemetría. Pasaron formato, `go vet`, pruebas con detector de carreras e integración MongoDB, además del recorrido de navegador. La pregunta social actual tiene un alcance menor que la guía y el mapa y las comparativas de rendimiento siguen pendientes.

Los componentes técnicos de las 14 actividades de esas semanas están documentados en [SEMANA_7_10.md](docs/SEMANA_7_10.md). El [cronograma y avance](#cronograma-y-avance-semanas-7-a-15) permite consultar rápidamente lo hecho y lo pendiente, incluida la brecha de impacto social. Las mediciones de escalabilidad, comparación final y despliegue final corresponden a semanas posteriores.

La [auditoría del 13 de octubre](docs/AUDITORIA_SEMANA_10.md) contrasta el cronograma adjunto y la guía y registra el cierre operativo local. La [evidencia nueva](docs/VERIFICACION_LOCAL_SEMANA_10.json) conserva conteos independientes de MongoDB, runs, salud del clúster y resultados de los chequeos.

Para preparar esta copia, ejecuta `./scripts/prepare-local.ps1`. Cuando Docker Desktop esté instalado e iniciado con motor Linux, ejecuta `./scripts/prepare-local.ps1 -StartDemo`: reproduce la demo y ejecuta formato, `go vet` y pruebas con detector de carreras dentro de Docker.

## Colaboradores y ramas

Cada colaborador tiene asignada una rama personal:

| Rama | Usuario de GitHub | Estado de acceso |
|---|---|---|
| `cueva` | [AXL031](https://github.com/AXL031) | Administrador |
| `lopez` | [VicuzS](https://github.com/VicuzS) | Colaborador con escritura |
| `taco` | [MiguelTacoZavala](https://github.com/MiguelTacoZavala) | Colaborador con escritura |
| `gerardo` | [Geleon515](https://github.com/Geleon515) | Colaborador con escritura |
| `dragon` | [FernanRojasR](https://github.com/FernanRojasR) | Colaborador con escritura |
| `vera` | [LeonardoVera](https://github.com/LeonardoVera) | Colaborador con escritura |

Asociación confirmada por el equipo el **5 de noviembre de 2026**. Las seis ramas existen localmente y en `origin`; el acceso de LeonardoVera está confirmado y su auditoría independiente se sigue en #8.

## Cronograma y avance (semanas 7 a 15)

**Desarrollo de issues 1–5 integrado en main:** correcciones de Dragon realizadas en `dragon`, resto en `cueva`; PR #14/#15 fusionadas por autorización del usuario con CI verde. Entrega de 63 muestras originales (12 cargas, 24 entrenamientos y 27 pasadas API / 27.000 intentos), en campañas separadas e identificadas. Meta operativa cumplida en 9/9 casos; los incumplimientos y errores permanecen visibles en el informe. Consulta [el cierre técnico y evidencia](docs/CIERRE_DESARROLLO_11_13.md). La auditoría independiente y documentos de Vera siguen en #8; la [auditoría inicial](docs/AUDITORIA_ISSUES_PR_2026_11_05.md) se conserva como historia previa a estas correcciones.

Actualización documental y regresión funcional por Go/scripts: **5 de noviembre de 2026**. Se conservaron los datos/modelo de la demo. El recorrido visual de navegador histórico es del 13 de octubre; la auditoría independiente nueva corresponde a Vera.

Fuente: [cronograma original en Excel](docs/Cronograma_Proyecto9_Go_BigData.xlsx), hoja **Hoja 1**, filas **2 a 26**. Se conservan las 25 actividades y sus semanas, indicadas por el color de las celdas del Excel. El archivo no asigna fechas calendario ni ponderaciones.

**Estados:** ✅ Hecho, con implementación y evidencia registrada. 🟡 Parcial, con avance y un cierre pendiente. ⬜ Pendiente, sin evidencia suficiente de cierre. Una semana queda completa cuando se cierran todas sus actividades.

| Semana / fila del Excel | Actividad del cronograma | Estado y evidencia / qué falta |
|---|---|---|
| **7 / 2** | Elegir dataset de más de 1M de registros y definir la pregunta de impacto social. | 🟡 **Parcial.** Hay 1,348,665 viajes persistidos y una pregunta sobre actividad registrada. Falta alinear con la guía el alcance de demanda no atendida o incorporar datos adicionales. |
| 7 / 3 | Configurar MongoDB y Redis en contenedores. | ✅ **Hecho.** Servicios separados, salud comprobada y volumen persistente de MongoDB. |
| 7 / 4 | Instalar y configurar Go, Docker y Docker Compose. | ✅ **Hecho.** Compilación Go dentro de Docker y preparación local reproducida; no se necesita Go en el host. |
| 7 / 5 | Diseñar las arquitecturas distribuida y de una sola máquina. | ✅ **Hecho.** Loader local concurrente, trainer secuencial y maestro/workers TCP documentados e implementados. |
| **8 / 6** | Dividir el archivo en bloques con goroutines y channels. | ✅ **Hecho.** Lectura CSV/Parquet, canales acotados y pool configurable, con pruebas de equivalencia. |
| 8 / 7 | Limpiar/parsear el dataset e insertarlo en MongoDB. | ✅ **Hecho.** Validación, rechazos por causa, escritura por lotes y carga idempotente comprobadas. |
| 8 / 8 | Implementar el maestro TCP con lógica parameter server. | ✅ **Hecho.** Maestro independiente que registra workers y conserva la autoridad sobre los parámetros. |
| **9 / 9** | Implementar workers con SGD sobre su partición de datos. | ✅ **Hecho.** Dos workers reales, con 3,960 tareas cada uno en la ejecución verificada. Se divide el cálculo por índices; cada worker carga una copia del snapshot. |
| 9 / 10 | Sincronizar gradientes parciales sin condiciones de carrera. | ✅ **Hecho.** Agregación ponderada y control de tarea/paso/versión; pruebas TCP y detector de carreras aprobados. |
| 9 / 11 | Implementar API REST en Go y autenticación JWT. | ✅ **Hecho.** Login, sesión, logout, protección de rutas y revocación comprobados. |
| **10 / 12** | Servir predicciones y telemetría en tiempo real por WebSocket. | ✅ **Hecho.** Predicciones correlacionadas, snapshots y reconexión verificados con cliente y navegador. |
| 10 / 13 | Integrar Redis como caché de predicciones. | ✅ **Hecho.** Claves versionadas, aciertos reales de caché y respaldo de cálculo cuando Redis falla. |
| 10 / 14 | Implementar SPA Angular/React que consuma REST y WebSocket. | ✅ **Hecho.** SPA React compilada, consultas, entrenamiento y recorrido autenticado comprobados. |
| 10 / 15 | Mostrar CPU, RAM y pérdida de entrenamiento del clúster. | ✅ **Hecho.** Mediciones reales de los procesos Go y curva de pérdida observadas durante entrenamiento. |
| **11 / 16** | Adaptar el cargador a un solo proceso con goroutines locales. | ✅ **Hecho, adelantado.** El loader ya ejecuta el pipeline en un proceso; `-workers` controla el paralelismo local. No es ingesta distribuida entre nodos. |
| 11 / 17 | Adaptar SGD a ejecución local sin parameter server entre nodos. | ✅ **Hecho, adelantado.** `trainer -mode sequential` ejecuta el núcleo SGD local, separado del modo distribuido. |
| 11 / 18 | Instrumentar tiempos de carga y entrenamiento en ambas versiones. | ✅ **Hecho, adelantado.** Loader registra segundos/filas por segundo y los runs guardan tiempos de entrenamiento. Falta usar esa instrumentación en los ensayos repetidos de la semana 12. |
| **12 / 19** | Probar carga y entrenamiento: distribuido frente a una sola máquina. | ✅ **Implementado y medido.** L1/L4 y S/D1/D2/D4: calentamientos y cinco medidas por caso, datos/configuración equivalentes, candidatos y modelos publicados comprobados. Revisión independiente: Vera #8. |
| 12 / 20 | Medir latencia de la API con objetivo menor de 100 ms. | 🟡 **Medición completa; evaluación por caso.** Tres estados Redis × concurrencia 1/10/25 × tres pasadas × 1.000 intentos. Meta operativa cumplida en 9/9 casos; los incumplimientos y errores permanecen visibles en el informe. [Tabla y evidencia](docs/CIERRE_DESARROLLO_11_13.md). |
| **13 / 21** | Evaluar rendimiento y escalabilidad distribuida. | ✅ **Implementado y medido.** Matriz real S/D1/D2/D4 con tareas de todos los workers y recursos/cobertura. Es un host con contenedores. Auditoría independiente pendiente en #8. |
| 13 / 22 | Elaborar el cuadro comparativo de tiempos, speedup y recursos. | ✅ **Cuadro técnico entregado.** Medianas, dispersión, speedup/eficiencia, CPU/RSS y contenedores en JSON/CSV e [informe técnico](docs/CIERRE_DESARROLLO_11_13.md). Vera produce el informe independiente final. |
| 13 / 23 | Realizar ajustes finales de código. | ✅ **Correcciones integradas en main y verificadas.** Referencias S, modelos publicados, logs por muestra, BSON, recursos activos, precalentamiento y mediciones desfavorables conservadas. CI y regresión aprobadas; auditoría independiente en #8. |
| **14 / 24** | Preparar Compose final con infraestructura separada de workers. | 🟡 **Parcial.** Compose ya diferencia servicios y permite escalar workers. Falta cerrar la configuración y el procedimiento de entrega final. |
| **15 / 25** | Probar despliegue en un entorno limpio. | ⬜ **Pendiente.** Registrar una instalación desde cero con requisitos, pasos y resultados; la reproducción local existente adelanta trabajo, pero no certifica una instalación limpia final. |
| 15 / 26 | Validar en otro entorno y realizar la demo final. | 🟡 **Parcial.** Hay evidencia histórica de otra computadora y reproducción en esta. Falta la validación de la versión final, el ensayo y la demo de entrega. |

### Prioridades para continuar

- [x] Preparar el clúster local con maestro y dos workers, datos reales y demo con inicio/apagado de un clic.
- [ ] Resolver la pregunta de impacto social de la semana 7 con el alcance de la guía.
- [x] Ejecutar los ensayos de semanas12–13 y entregar el cuadro técnico, sin asumir aceleración. Vera (#8) conserva la auditoría y el informe independiente.
- [ ] Cerrar Compose y las validaciones de entrega de las semanas 14 y 15.
- [ ] Incorporar el mapa de zonas solicitado por el contexto general, sin fila específica en el Excel.
- [ ] Completar el informe final. Checkpoints y reasignación de tareas continúan como ampliaciones del [plan de desarrollo](docs/PLAN_DESARROLLO.md), sin semana propia en el Excel.

**Límite del avance:** los componentes técnicos hasta semana 10 están verificados, pero la pregunta social mantiene una brecha. La validación seleccionó persistencia y todavía no se ha demostrado mejora predictiva ni aceleración. Por eso no se declara 100% del proyecto completo ni del contexto general.

Detalle de respaldo: [auditoría y brechas](docs/AUDITORIA_SEMANA_10.md), [matriz técnica de semanas 7–10](docs/SEMANA_7_10.md) y [evidencia local](docs/VERIFICACION_LOCAL_SEMANA_10.json). Al cerrar una actividad, actualizar su estado y enlazar su evidencia con fecha; no marcarla como terminada solo por tener código.

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

Benchmarks repetidos, cuatro workers reales y cuadro técnico de escalabilidad/recursos entregados; auditoría independiente pendiente de Vera (#8). Despliegue limpio y validación final en otro entorno siguen en semanas14–15. El plan general también contempla mapa y recuperación con checkpoints.

```powershell
docker compose down
```

Conserva MongoDB. No agregues `--volumes` para mantener datos. Conserva también `data/processed` para reentrenar. Reiniciar API exige iniciar sesión de nuevo.
