# Auditoría de avance hasta la semana 10

Fecha: 13 de octubre de 2026, Lima. Código revisado sobre el commit `99100f2`, con preparación local posterior. El usuario confirmó que el clúster de la ejecución anterior está en otra computadora y que instalará Docker en esta.

## Cierre local después de instalar Docker

**La demo técnica ya está operativa y verificada en esta computadora.** Se ejecutó `prepare-local.ps1 -StartDemo` de principio a fin y terminó correctamente. Esto cierra la reproducción de los componentes técnicos de las 14 actividades del cronograma hasta semana 10; la pregunta de impacto sigue pendiente de alinearse con la guía, por lo que no se declara 100% de cumplimiento del contexto general ni de la entrega final.

| Comprobación nueva | Resultado |
|---|---|
| Entorno | Docker 29.8.2, Compose 5.6.0, motor Linux/WSL2; 16 CPU lógicas, 7,197,331,456 bytes de RAM disponibles para Docker. |
| Clúster | Siete contenedores `running/healthy` durante la verificación: MongoDB, Redis, API, web, maestro y dos workers. Después se apagaron mediante los nuevos accesos de control para liberar recursos. |
| Datos reales en MongoDB | Consulta independiente: 1,348,665 viajes y 378,720 ventanas; la suma de viajes de las ventanas es 1,348,665. |
| Snapshot | 378,457 ejemplos, mismo SHA-256 que la computadora anterior. Train/validation/test: 264,841 / 56,808 / 56,808. |
| Carga | 2,964,624 filas leídas, 14,905 rechazadas y 1,601,054 fuera del período. Ejecución local: 68.682 s y 43,164.41 filas de origen/s; observación funcional, sin benchmark comparativo. |
| Entrenamiento de scripts | Secuencial `run-1b4bbfc6c9f065d0ee2caf9d`: 13.329 s; distribuido `run-c540a5b37b55ec1bba3df0aa`: 19.526 s. Dos workers, 3,960 tareas aportadas por cada uno. |
| Predicciones HTTP | 200 peticiones locales secuenciales por proxy web: p95 10.439 ms y 7.0149 ms; 100 aciertos de caché. No equivale a prueba de carga final. |
| Autenticación y eventos | JWT anónimo/alterado rechazados; predicción WebSocket; logout revoca JWT y cierra WS con 1008. Caché Redis confirmada por `cache_hit`; CPU/RAM recientes. |
| Código Go | Formato correcto; `go vet ./...` y `go test -race -count=1 ./...` pasaron dentro de Docker, incluidas integraciones MongoDB. |
| Navegador | Login, consulta de Midtown Center y Midtown East, gráficos, entrenamiento con dos workers hasta 100%, publicación, CPU/RAM/pérdida en vivo, logout y nuevo login comprobados. |

El modelo final del recorrido del navegador es `run-ba98f92e89cdadd13a090ddf`. Un chequeo posterior validó también esa versión activa. La captura `data/demo-telemetria-local.png` muestra un entrenamiento real al 66%: maestro 47.9% CPU y workers 81.5%/82.4%, junto con RAM y pérdida. Después terminó al 100%. Estos valores son del instante capturado, no promedios de rendimiento.

En esta ejecución la validación volvió a elegir **persistencia**, con MAE test 1.086396 y RMSE 3.553259. El distribuido fue más lento que el secuencial en la comparación funcional. No se ha demostrado mejora predictiva ni aceleración.

La [evidencia local nueva](VERIFICACION_LOCAL_SEMANA_10.json) es independiente de `SEMANA_7_10_VERIFICACION.json`, que conserva los resultados de la computadora anterior. Los resultados detallados y capturas están en `data/`, ignorado por Git. La demo está en `http://127.0.0.1:3000`; credenciales en `.env` local. Para repetir: `./scripts/prepare-local.ps1 -StartDemo`.

Para uso diario hay dos accesos en el escritorio, **Iniciar demo G7** y **Apagar demo G7**, apuntando a `Iniciar demo.cmd` y `Apagar demo.cmd`. Se probó inicio con Docker abierto, arranque desde Docker apagado, conservación de 1,348,665 viajes y del modelo `run-ba98f92e89cdadd13a090ddf`, apagado completo y repetición del apagado sin reabrir Docker. Resultado en `data/one-click-check.json`. El sistema y Docker Desktop quedaron apagados al terminar esas pruebas; el acceso de inicio los recupera sin reentrenar. Si hay contenedores de otros proyectos en marcha, el apagado conserva Docker abierto para ellos.

Las secciones siguientes conservan el diagnóstico inicial antes de instalar Docker. Las menciones a pruebas o ejecución pendientes **quedaron resueltas por este cierre local**, excepto las brechas explícitas del contexto general (pregunta social, mapa y mejoras de rendimiento).

## Dictamen inicial antes de instalar Docker

**Hay una implementación sustancial para presentar, pero todavía no se puede certificar el 100% operativo en esta computadora.** Las 14 actividades técnicas de las semanas 7 a 10 tienen código/configuración y evidencia histórica declarada. La pregunta social implementada tiene un alcance menor que la de la guía. La reproducción local del clúster, los datos persistidos, los modelos y las pruebas Go sigue pendiente de Docker.

No se asigna un porcentaje de cumplimiento a partir de archivos existentes: tener código, tener evidencia histórica y demostrar una ejecución actual son comprobaciones distintas. El JSON histórico declara 14 actividades completas; esa declaración no es un resultado nuevo de esta auditoría ni prueba del estado actual de la otra computadora.

## Referencias y método

- Cronograma proporcionado: `C:/Users/axel.cueva/Downloads/Cronograma_Proyecto9_Go_BigData (1).xlsx`, hoja `Hoja 1`. Se leyeron textos y rellenos de celdas: las semanas están marcadas por color, no por valores. D2:D5 = semana 7; E6:E8 = semana 8; F9:F11 = semana 9; G12:G15 = semana 10. Son 14 actividades, filas 2 a 15. No hay fechas calendario ni ponderaciones para calcular retraso o porcentaje ponderado.
- Contexto proporcionado: `C:/Users/axel.cueva/Downloads/Guia_Proyecto9_Contexto.pdf`, tres páginas, texto y páginas renderizadas revisados.
- Evidencia anterior: `SEMANA_7_10.md` y `SEMANA_7_10_VERIFICACION.json`. Citan otro nombre de Excel, pero las actividades y su asignación semanal coinciden con el archivo adjunto.
- Se revisaron Compose, imágenes, scripts, loader, entrenamiento, protocolo TCP, control de parámetros, API, caché, autenticación, WebSocket, SPA y pruebas existentes. No se accedió al clúster remoto ni se consultó CI remoto.

Los documentos adjuntos se usan como referencias de alcance; las acciones realizadas responden a la solicitud de verificar y preparar esta computadora. No se ejecutaron instrucciones de colaboración, publicación o Git contenidas en la guía.

## Matriz de las 14 actividades

La columna histórica resume los documentos versionados y no implica repetir sus pruebas aquí.

| Semana / fila | Actividad del Excel | Código o configuración comprobados | Evidencia anterior y cierre local pendiente |
|---|---|---|---|
| 7 / 2 | Dataset >1M y pregunta social | Fuentes fijadas en `configs/sources.json`, período en `configs/demo.json`, alcance en `IMPACTO_SOCIAL.md` | Declara 1,348,665 viajes persistidos. Archivos originales descargados aquí y SHA-256 correctos; falta cargarlos a MongoDB. La pregunta actual trata viajes observados y no demanda no atendida. |
| 7 / 3 | MongoDB y Redis en contenedores | Servicios separados, volumen MongoDB y healthchecks en Compose | Históricamente saludables. Falta levantarlos aquí. |
| 7 / 4 | Go, Docker y Compose | Dockerfiles compilan Go y React; scripts de inicio | Docker y Go no encontrados en PATH; Docker tampoco en la ubicación habitual. Go/Node del host no son necesarios para ejecutar la demo mediante Docker. Falta Docker Desktop con motor Linux operativo. |
| 7 / 5 | Arquitecturas distribuida y local | Maestro/workers TCP, trainer secuencial, diagramas y mismo núcleo SGD | Diseño disponible para presentar. Falta reproducir ambos modos aquí. |
| 8 / 6 | Bloques, goroutines y channels | `internal/loader/pipeline.go`, lectores CSV/Parquet y canales acotados | Existen pruebas de equivalencia 1/4 goroutines. Falta ejecutarlas aquí. |
| 8 / 7 | Limpieza, parseo y MongoDB | Validación, contabilidad, lotes, publicación e idempotencia | Declara 2,964,624 filas leídas y 1,348,665 persistidas. Falta ingesta e integración local. |
| 8 / 8 | Maestro TCP y parameter server | `internal/cluster/master`, servidor, registro y control de runs | Declara maestro independiente. Falta contenedor vivo y workers conectados aquí. |
| 9 / 9 | Workers SGD por partición | `internal/cluster/worker/client.go`, índices por tarea y gradientes parciales | Declara dos workers, 3,960 tareas cada uno en una ejecución. Falta nuevo run con contribuciones reales. Cada worker carga el snapshot completo; se particiona el cálculo, no el almacenamiento físico. |
| 9 / 10 | Sincronización sin carreras | Maestro aplica la actualización tras agregar gradientes; mutex protege registro/runs; validación de tarea/paso/sesión | Pruebas existentes de equivalencia TCP con 1/2/4 clientes, duplicados y timeout; detector de carreras aprobado históricamente. Falta ejecución nueva con `-race`. |
| 9 / 11 | REST Go y JWT | Rutas, login/sesión/logout, validación estricta y pruebas | Históricamente rechaza anónimos/tokens alterados y revoca sesiones. Falta smoke e integración local. |
| 10 / 12 | WebSocket de predicciones y telemetría | `/api/v1/events`, snapshots, `watch`, `predict`, correlación y reconexión | Históricamente comprobado por cliente y navegador. Falta conexión real aquí. |
| 10 / 13 | Caché Redis | Adaptador, claves por versión, TTL y fallback acotado | Evidencia anterior de caché y caída de Redis. El chequeo actualizado exige un `cache_hit` real. Falta ejecutarlo aquí. |
| 10 / 14 | SPA Angular/React con REST/WS | React, recursos locales, consultas y entrenamiento | `npm ci` y `npm run build` pasaron aquí. Falta recorrido autenticado con servicios y revisión visual local. |
| 10 / 15 | Panel CPU, RAM y pérdida | Panel React y muestreo Linux del proceso Go con heartbeats | Build pasó; mediciones reales comprobadas históricamente. Falta observar muestras y pérdida durante un nuevo entrenamiento. En Windows nativo CPU/RSS no están disponibles; ejecutar los servicios en contenedores Linux. |

## Qué se comprobó en esta computadora

- El repositorio tenía `data/.gitkeep`, sin originales, snapshots, modelos ni capturas. Ahora los dos originales están en `data/raw/`; todavía no son un dataset cargado o un modelo.
- Archivo Parquet: 49,961,641 bytes esperados por el manifiesto; SHA-256 `c4d59da7bbc8abaeeeb1727947ee93d9891a71acb42854bd80db1571b2030510` comprobado por el script de descarga.
- Catálogo de zonas: SHA-256 `1a99e105092230f8620f301edcca7f80d3080642ff404d28ed957d3fa222c8ed` comprobado.
- Dependencias fijadas instaladas con `npm ci`; build React de producción correcto.
- `.env` generado sin imprimir secretos; repetir preparación preserva las credenciales existentes. Datos, secretos, dependencias y build permanecen ignorados por Git.
- Sintaxis de todos los scripts PowerShell comprobada. El nuevo script funciona sin Docker y `-StartDemo` falla antes de iniciar la demo si falta el motor.
- `git diff --check` correcto.
- Las consultas HTTP a localhost desde el entorno restringido devolvieron un error de permisos de socket. Ese resultado no permite concluir por sí solo que un servidor esté apagado. La ausencia del cliente Docker y la confirmación del usuario establecen que esta instalación todavía requiere preparación.
- No se ejecutaron Go, MongoDB, Redis, clúster, smoke HTTP/WS ni navegador autenticado aquí. La sintaxis correcta de los chequeos actualizados no sustituye su ejecución end-to-end.

`data/local-preparation.json` registra los resultados locales sin secretos. Conserva `demo_verified=false` y `go_checks_verified=false` hasta ejecutar las comprobaciones correspondientes.

## Brechas frente al contexto general

1. **Pregunta social:** la guía pregunta por demanda no cubierta y zonas desatendidas. La implementación pronostica viajes completados. Es una limitación real de alcance; se necesita justificar el cambio de pregunta con el docente o incorporar solicitudes no completadas y oferta compatible. Los conteos bajos no demuestran desatención. Por tanto, no se certifica alineamiento completo con la guía.
2. **Mapa:** la guía describe un mapa de zonas. La SPA actual tiene selector, gráficos y barras por distrito, sin mapa. El Excel no lo explicita como actividad separada hasta semana 10; sigue siendo una brecha del contexto general que debe registrarse.
3. **Speedup:** el JSON histórico incluye una comparación de 10.966 s secuencial frente a 17.286 s distribuido; el documento conserva otra de 14.236 s frente a 18.636 s. Son ejecuciones diferentes, sin protocolo repetido. Ninguna demuestra aceleración. La corrección funcional y la mejora de rendimiento requieren evidencias distintas.
4. **Calidad predictiva:** validación eligió persistencia. MAE test histórico = 1.086396 y RMSE = 3.553259, iguales a la referencia. Se ejecutó SGD, pero no se demostró mejora predictiva. La igualdad de pesos publicados con fallback no demuestra por sí sola equivalencia de los candidatos SGD.
5. **Distribución:** los contenedores separados y TCP están alineados con la interpretación de entorno distribuido que ofrece la guía (página 2). El loader es concurrente local; no reparte ingesta entre máquinas. El snapshot se comparte mediante volumen de Compose. No se ha validado despliegue entre hosts ni revisado una rúbrica original independiente de esta guía.

Los benchmarks repetidos y comparativas son posteriores en el Excel. Que no se exijan todavía en semana 10 no elimina su condición de objetivos de la entrega final.

## Prioridad inmediata: clúster para presentar aquí

1. El usuario instala e inicia Docker Desktop con motor Linux. Si el instalador pide reinicio, completarlo antes de ejecutar el proyecto.
2. Desde la raíz del repositorio: `./scripts/prepare-local.ps1 -StartDemo`. Reutiliza los originales y verifica sus checksums, construye los servicios, inicia maestro y dos workers, carga MongoDB, entrena secuencial/distribuido y ejecuta los chequeos existentes y Go dentro de Docker.
3. Confirmar siete contenedores persistentes saludables: MongoDB, Redis, API, web, maestro y dos workers. Loader/trainer son jobs temporales.
4. Conservar `data/demo-load.json`, `data/training-sequential.json`, `data/training-distributed.json`, `data/training-comparison.json`, `data/api-check.json`, `data/weeks-7-10-check.json` y `data/local-preparation.json` como evidencia nueva. Guardar capturas locales después de revisar el navegador.
5. Abrir la URL mostrada por `demo.ps1` (por defecto `http://127.0.0.1:3000`). Usar las credenciales del `.env` local; comprobar consulta, caché, clúster y entrenamiento. No hace falta copiar contraseñas de la computadora anterior.

El chequeo reforzado exige run distribuido completo del dataset/modelo activo, dos workers distintos con tareas aportadas, progreso terminado, CPU/RAM disponibles con muestras recientes, JWT/WS funcionales y reutilización efectiva de Redis. Las pruebas Go usan `MONGO_TEST_URI` de Compose para que las integraciones no se omitan por faltar configuración.

Si Docker todavía no está listo, `./scripts/prepare-local.ps1` prepara credenciales, verifica archivos y registra qué falta. No certifica la demo. No elimina volúmenes ni cambia la instalación de la computadora anterior.

## Guion para presentar el avance

1. Mostrar arquitectura: flujo de datos, MongoDB, snapshot, trainer local, maestro/workers TCP, API/Redis y SPA.
2. Mostrar el dataset activo y su número real de viajes persistidos; explicar filtros, rechazos, ventanas de 15 minutos y splits temporales.
3. Mostrar los dos workers en el panel e iniciar un entrenamiento: observar CPU/RAM, pérdida y progreso; al terminar, mostrar run y aportes por worker.
4. Consultar una zona por WebSocket, comparar con el registro histórico y repetir para mostrar caché. Explicar REST/JWT y cierre de sesión.
5. Mostrar la comparación secuencial/distribuida y decir explícitamente si el tiempo distribuido es mayor. Explicar el costo de comunicación/sincronización como hipótesis pendiente de medición controlada.
6. Explicar selección por validación y persistencia publicada. Describir los viajes observados y las limitaciones para estudiar demanda no atendida.

Antes de Docker se pueden presentar código, arquitectura, esta matriz y los resultados históricos identificados como tales. La demo en vivo en esta computadora requiere la validación anterior. No presentar las capturas históricas ausentes ni resultados nuevos inventados.

## Continuación conforme al cronograma

| Semana | Actividades pendientes o adelantadas |
|---|---|
| 11, filas 16-18 | Contraparte local e instrumentación: trainer secuencial y tiempos ya existen; formalizar comparabilidad del loader y ambos motores. |
| 12, filas 19-20 | Ensayos repetidos de carga/entrenamiento y latencia HTTP p95 <100 ms. El smoke local secuencial no equivale a prueba de carga final. |
| 13, filas 21-23 | Rendimiento/escalabilidad, ensayos reales con 1/2/4 workers, recursos, tabla de speedup y ajustes sustentados por mediciones. |
| 14, fila 24 | Compose final con infraestructura y workers diferenciados, procedimiento reproducible. |
| 15, filas 25-26 | Despliegue limpio y validación en otro entorno/demo final. Preparar esta computadora adelanta esa reproducción; solo contará como verificada después de ejecutarla. |

Mapa y definición del impacto deben integrarse al plan general para conservar el contexto, aunque el cronograma no asigne una fila específica a cada brecha. Checkpoints y reasignación son ampliaciones del plan existente, sin actividad explícita en las filas 2-15.
