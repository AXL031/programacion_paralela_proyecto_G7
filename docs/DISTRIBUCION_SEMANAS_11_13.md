# Reparto del trabajo y flujo de revisión: semanas 11 a 13

Fecha: **5 de noviembre de 2026, Lima**.

Este documento reparte el [plan técnico hasta la semana 13](PLAN_SEMANAS_11_13.md). Define responsables, límites, dependencias, entregables y el contenido de los issues. **La asignación no significa que el desarrollo ni las mediciones estén hechos.**

## 1. Responsables

| ID | Integrante / GitHub | Rama obligatoria | Responsabilidad principal | Issue |
|---|---|---|---|---|
| CUEVA | Cueva / [AXL031](https://github.com/AXL031) | `cueva` | Entorno aislado, contratos de evidencia, runner e integración | [#1](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/1) |
| LOPEZ | López / [VicuzS](https://github.com/VicuzS) | `lopez` | Cargador local, instrumentación e ingesta L1/L4 | [#2](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/2) |
| TACO | Taco / [MiguelTacoZavala](https://github.com/MiguelTacoZavala) | `taco` | SGD local/distribuido, fases y equivalencia de candidatos | [#3](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/3) |
| GERARDO | Gerardo / [Geleon515](https://github.com/Geleon515) | `gerardo` | Recursos, campañas S/D1/D2/D4 y cuadro de escalabilidad | [#4](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/4) |
| DRAGON | Dragon / [FernanRojasR](https://github.com/FernanRojasR) | `dragon` | Generador HTTP, concurrencia y matriz de API/Redis | [#5](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/5) |
| VERA | Vera / [LeonardoVera](https://github.com/LeonardoVera) | `vera` | Verificación independiente, informe y comparación final | **Pendiente: crear después de que acepte la invitación** |

Los cinco issues activos están creados con su responsable asignado. El texto de Vera queda preparado aquí, pero no se publicará su issue ni se le solicitará revisión mientras no tenga acceso confirmado.

## 2. Cobertura del cronograma

| Semana / fila | Actividad | Responsable de ejecución | Apoyo / validación |
|---|---|---|---|
| 11 / 16 | Contraparte de ingesta local | López | Cueva integra; Vera audita al incorporarse |
| 11 / 17 | Contraparte SGD local | Taco | Gerardo consume el resultado; Cueva revisa |
| 11 / 18 | Tiempos de carga y entrenamiento | López y Taco, cada uno en su componente | Cueva define formato; Gerardo captura recursos |
| 12 / 19 | Comparación carga/entrenamiento | López: L1/L4; Gerardo: S/D2 | Taco verifica SGD; Cueva orquesta |
| 12 / 20 | Latencia API <100 ms | Dragon | Cueva prepara aislamiento; Vera audita resultados |
| 13 / 21 | Escalabilidad | Gerardo | Taco: entrenamiento; Cueva: entorno |
| 13 / 22 | Cuadro de tiempos, speedup y recursos | Gerardo produce tablas; Vera explica y contrasta | Cueva integra; López y Dragon entregan sus métricas |
| 13 / 23 | Ajustes finales | Cada propietario corrige su componente | Cueva coordina/revisa; Vera verifica regresión |

Todos los requisitos quedan asignados. La semana 13 no se cierra si faltan la verificación y el informe de Vera o su reasignación explícita. La pregunta social y el mapa permanecen como brechas registradas en el plan técnico; este reparto no los declara resueltos.

## 3. Forma de trabajar con ramas, issues y PR

1. Cada integrante trabaja en la rama personal indicada en la tabla; los PR tienen **base `main`**. No se desarrollará directamente en `main`.
2. Antes de empezar, descargar referencias y actualizar la rama personal con la última versión aprobada de `main`. Conservar los cambios propios antes de integrar; no borrar trabajo ni forzar el push para sincronizar.
3. Abrir un **PR en borrador** cuando haya trabajo revisable y enlazar su issue. Explicar qué parte resuelve y qué dependencias aún faltan.
4. Cuando pase los chequeos, marcarlo listo para revisión. **Cueva revisa los PR del equipo.** Los cambios solicitados se corrigen en la misma rama/PR.
5. Para un PR de Cueva, pedir revisión a **otro colaborador activo**. GitHub no permite que el autor apruebe su propio PR. El revisor se elige al abrirlo: López o Gerardo son posibilidades, no dos aprobaciones obligatorias ni cargos de revisión ya asignados.
6. Ningún PR se fusiona automáticamente. Se requiere al menos una revisión independiente aprobatoria, conversaciones resueltas y comprobaciones aplicables satisfactorias. El autor no fusiona su propio PR por su cuenta. Cueva autoriza las integraciones; si es autor, lo hace después de la revisión de otro integrante.
7. Si un issue requiere varios PR, el primero describe un avance y el **último** usa `Closes #N` cuando cumpla todos los criterios. No cerrar el issue solo por abrir el PR o por entregar código sin mediciones.
8. Después de un merge aprobado, los demás actualizan sus ramas desde `main`. Mantener las seis ramas personales para próximas tareas; no eliminarlas automáticamente.

Ejemplo para López, ejecutado por el integrante cuando tenga su copia preparada:

```powershell
git fetch origin
git switch lopez
git merge origin/main
# Implementar, verificar y crear commits de la tarea.
git push origin lopez
gh pr create --base main --head lopez --draft
```

Estos comandos son instrucciones de trabajo, no tareas ejecutadas por crear el documento. La regla de aprobación se documenta aquí; este reparto **no configura protección de ramas ni permisos nuevos en GitHub**.

### Contenido obligatorio del PR

- Issue y responsable; rama de origen y base `main`.
- Problema que resuelve, comportamiento resultante y archivos principales.
- Cómo reproducirlo y qué comandos de prueba se ejecutaron, con resultado.
- Evidencia de fixtures o de campaña real según el alcance del PR.
- Compatibilidad con la demo, dataset/modelo previos y contratos existentes.
- Limitaciones, dependencias pendientes y comparación antes/después si hay optimización.
- Sin credenciales, JWT, tokens, datasets grandes ni salidas de compilación.

## 4. Dependencias y orden de integración

El trabajo se divide en entregas parciales para que la integración no dependa de un único PR grande.

| Orden | Entrega | Responsable | Requisitos previos |
|---|---|---|---|
| 0 | Este reparto, plan técnico y cronograma accesibles al grupo | Cueva | Revisión documental antes del merge |
| 1 | Contrato de resultados y entorno aislado | Cueva, primer PR de su issue | Plan/reparto disponibles |
| 2A | Instrumentación y comprobación de carga | López | Contrato aprobado; fixtures permiten empezar antes de la campaña |
| 2B | Fases y candidatos SGD previos a selección | Taco | Contrato aprobado; reutilizar pruebas existentes |
| 2C | Captura de recursos y agregaciones | Gerardo, primer PR | Contrato aprobado; puede usar muestras de prueba identificadas como tales |
| 2D | Generador HTTP concurrente y validadores | Dragon, primer PR | Contrato aprobado; puede probarlo con servidor controlado |
| 3 | Runner integrado y smoke de campaña | Cueva, siguiente PR | Interfaces de López, Taco, Gerardo y Dragon integradas |
| 4 | Campañas reales: L1/L4, S/D1/D2/D4 y API | López, Gerardo y Dragon | Entorno/runner listos; API necesita dataset y modelo válidos |
| 5 | Correcciones justificadas y repetición afectada | Propietario del componente | Resultados reales y diagnóstico compartido |
| 6 | Verificación independiente e informe final | Vera | Acceso aceptado y entregas/campañas integradas |

**Dependencias sin ciclos:** el primer PR de Cueva entrega contratos y entorno; su integración posterior consume componentes. Los issues de componentes pueden entregar su código antes del runner completo mediante fixtures. Ningún responsable necesita esperar a que el issue completo de Cueva se cierre para empezar. El cierre del issue de Cueva certifica integración, no sustituye la auditoría final de Vera.

El desarrollo de componentes puede avanzar a la vez. **Las mediciones formales en el mismo host se ejecutan por turnos** acordados por Cueva para evitar competencia de CPU/RAM/disco. No mezclar resultados de computadoras o versiones diferentes en una campaña.

Si la invitación de Vera se demora, los cinco activos continúan con código, pruebas y evidencias. La auditoría final queda pendiente; cualquier reasignación de esa responsabilidad debe decidirse expresamente y actualizar este documento. No se asumirá una aceptación de invitación por el paso del tiempo.

## 5. Contrato y protocolo compartidos

Cueva documentará antes de integrar componentes el contrato `benchmark-v1` en `docs/CONTRATO_BENCHMARK.md`. Los nombres de campos concretos se fijan en ese PR; el contenido mínimo es:

| Área | Datos mínimos |
|---|---|
| Identidad | Versión de esquema, campaña, caso, repetición, calentamiento/medición, responsable, inicio/fin UTC |
| Referencia | Commit y estado del diff, imagen/binario y hash de configuración, entorno y límites de recursos |
| Datos/modelo | Dataset ID, load ID, hashes fuente/catálogo/snapshot, configuración, splits y versión de modelo cuando aplique |
| Resultado | Estado válido/fallido, errores/causa, unidades y alcance de cada medida |
| Tiempos | Preparación, núcleo, evaluación/selección, publicación, total; fases que no aplican se distinguen de fases sin instrumentar |
| Recursos | Serie temporal, CPU/RSS del proceso, CPU/memoria de contenedor, identidad del servicio, cobertura y muestras faltantes |
| Comprobaciones | Conteos, reutilización, equivalencia numérica, contribución por worker o respuestas/caché según el caso |
| Salidas | Rutas de resultados compactos y evidencia bruta, con checksums para rastrear los agregados |

Convenciones que todo issue debe respetar:

- Datos/configuración principal: `configs/demo.json` y `configs/training.json`. No cambiar período, splits, épocas, batch o semilla solo para mejorar la comparación.
- Carga/entrenamiento: un calentamiento y **cinco repeticiones medidas por caso**, orden alternado/rotado y registrado. Una reducción a tres requiere acuerdo y campaña identificada aparte.
- Carga L1/L4: misma configuración y presupuesto de CPU; MongoDB vacío de ensayo; **`reused=false`**; conteos y snapshot equivalentes. La ingesta actual es local, no multinodo.
- Entrenamiento S/D1/D2/D4: mismo snapshot e hiperparámetros; número exacto de workers sanos, todos con tareas; comparación de candidatos antes de `ml.Select` y de modelos publicados por separado.
- Tolerancia numérica inicial: por parámetro `abs(a-b) <= 1e-9 + 1e-9 * max(abs(a), abs(b))`, validada con pruebas y registrada. No reemplazarla por una comparación de hashes de floats.
- API: tres estados de Redis × concurrencia 1/10/25 × tres pasadas × 1,000 solicitudes medidas; login/precalentamiento fuera de medición. p95 <100 ms y cero errores inesperados es el criterio operativo propuesto, distinto de medir cada respuesta individual.
- Aislamiento: proyecto Compose, bases, Redis, puertos y directorios propios. Toda limpieza valida que actúa sobre recursos de benchmark; nunca borra datos de la demo.
- Recursos: muestreo aproximadamente cada segundo y cobertura registrada; CPU del proceso 100% = un núcleo; RSS, heap y memoria del contenedor son medidas distintas. Sumar RAM en instantes alineados.
- Resultados compactos en `bench/results/<campaña>/`; datos grandes en `bench/raw/<campaña>/` y `data/bench/<campaña>/`. Como el bruto está ignorado por Git, el PR indicará una ubicación accesible al grupo, manifiesto/checksums y cómo reproducirlo. Un archivo que solo existe en una PC no basta para la revisión.
- Registrar fallos y resultados desfavorables. No presentar tests de fixtures, datos sintéticos o antecedentes de octubre como mediciones nuevas reales.

## 6. Archivos y coordinación para evitar conflictos

| Propietario | Archivos o áreas de su responsabilidad |
|---|---|
| Cueva | `docker-compose.benchmark.yml`, `configs/benchmark.json`, `scripts/benchmark.ps1`, `docs/CONTRATO_BENCHMARK.md`, tipos/formato compartidos de `internal/benchmark/`, manifiestos y configuración de campaña |
| López | `cmd/loader/`, `internal/loader/`, `scripts/benchmark-load.ps1`, `docs/BENCHMARK_CARGA.md`, resultados L1/L4 |
| Taco | `cmd/trainer/`, `internal/training/`, pruebas numéricas de `internal/ml/` e integración, `docs/BENCHMARK_ENTRENAMIENTO.md` |
| Gerardo | `scripts/benchmark-training.ps1`, `scripts/benchmark-resources.ps1`, agregaciones en `internal/benchmark/`, `docs/BENCHMARK_ESCALABILIDAD.md`, resultados S/D1/D2/D4 y recursos |
| Dragon | `cmd/benchmark-api/`, sus pruebas, `scripts/benchmark-api.ps1`, `docs/BENCHMARK_API.md`, resultados de API |
| Vera | `scripts/check-weeks-11-13.ps1`, `docs/SEMANA_11_13.md`, `docs/VERIFICACION_SEMANA_13.json`, actualización final de avance en README y `docs/PLAN_DESARROLLO.md` |

`internal/benchmark/` es compartido por Cueva y Gerardo: separar contrato/formato de estadísticas en archivos distintos y acordar sus interfaces en la primera entrega. El agregador puede ser una utilidad Go o una parte reutilizable del runner; acordar el punto de entrada antes de implementarlo. Dragon no debe duplicar una biblioteca estadística si ya está disponible.

`internal/telemetry/` y `internal/cluster/master/` pueden requerir cambios de Taco/Gerardo. Antes de editarlos, indicar en el issue qué archivo toca cada uno y coordinar el orden del PR. Cueva revisa cualquier cambio transversal. No cambiar archivos ajenos solo para corregir estilo.

Los nombres de archivos nuevos son entregables propuestos, no implementación existente. Cada PR puede ajustar la organización con justificación, siempre que conserve responsabilidades e interfaces.

## 7. Contenido detallado por integrante

Las seis secciones siguientes sirven de base para los issues. Cada issue publicado debe incluir además el protocolo y el flujo de PR de este documento, y enlaces a los otros issues de los que dependa.

<!-- tarea:CUEVA:inicio -->
### CUEVA — Preparar entorno, contrato y runner de benchmarks

**Responsable:** @AXL031. **Rama:** `cueva`. **Semanas:** soporte de 11/18, 12/19–20 y 13/21–23. **Prioridad:** iniciar primero; integrar por entregas.

**Objetivo:** que el equipo tenga un entorno de medición reproducible y aislado, un formato común de evidencia y un runner que ejecute los componentes aprobados.

**Tareas:**

1. Congelar la referencia efectiva: commit, diff, configuraciones, hashes de datos y versiones. Distinguir código base, metadatos de campaña y resultados medidos; no usar fechas como sustituto del commit.
2. Verificar Docker Linux, CPU/RAM/disco y el fallo de arranque registrado. Documentar solución y requisitos sin reinstalar o borrar volúmenes como primera medida.
3. Crear `docker-compose.benchmark.yml`: proyecto/volúmenes, MongoDB, Redis, base, puertos, modelos y salida exclusivos. Configurar límites y `GOMAXPROCS` explícitos, y registrar ambos. Evitar colisiones con la demo.
4. Acordar/publicar `benchmark-v1`, tipos/formato y `configs/benchmark.json`: casos, calentamientos, repeticiones, orden, concurrencias, tolerancias y criterios. Definir los parámetros/JSON de entrada y salida de cada subscript antes de que otros lo integren.
5. Entregar un primer PR con contrato, entorno y smoke; permitir que los componentes continúen desde esa base aprobada.
6. Implementar `scripts/benchmark.ps1` para validar precondiciones, despachar carga/entrenamiento/API, registrar campaña, impedir solapamiento, conservar stdout/stderr y fallos y devolver un estado no exitoso ante casos ausentes o inválidos.
7. Integrar los scripts de López/Gerardo/Dragon, la instrumentación de Taco y el agregador. Los scripts de componente reciben explícitamente campaña, configuración y entorno aislado; no mantienen proyectos o bases ocultos.
8. Definir retención/limpieza segura, ubicar evidencia bruta accesible al grupo con manifiesto y comprobar dataset/modelo de la demo antes y después.
9. Coordinar turnos de medición y PR. Cerrar integración con un smoke completo; no declarar auditada la entrega final que corresponde a Vera.

**Archivos:** Compose/config/runner/contrato y formato compartido indicados en la sección 6. Cambiar infraestructura de demo solo si se demuestra imprescindible y se justifica en el PR.

**Dependencias:** primer PR independiente de los demás; integración final consume las entregas de López, Taco, Gerardo y Dragon. No bloquear el arranque de ellos hasta el cierre de todo este issue.

**Criterios de aceptación:**

- [ ] Entorno aislado sano; ninguna limpieza ni publicación afecta a la demo.
- [ ] Contrato, configuración e interfaz de subscripts documentados y verificables.
- [ ] Se registran commit/diff, datos, imágenes, recursos, orden y estado de cada muestra.
- [ ] Un caso faltante/fallido, base equivocada o ejecución solapada produce error visible.
- [ ] Runner integrado ejecuta un smoke con fixtures; los fixtures quedan etiquetados.
- [ ] Instrucciones reproducibles, ubicación de evidencia y conservación de demo comprobadas.
- [ ] PR(s) desde `cueva` a `main`, con revisión independiente de otro colaborador; el último cierra este issue.

**Verificación:** validar resolución de Compose sin imprimir secretos, sintaxis PowerShell, fixtures de orquestación y caminos de error; pruebas Go/race e integración si se añaden tipos/lógica Go. El smoke no sustituye campañas reales de los otros issues.
<!-- tarea:CUEVA:fin -->

<!-- tarea:LOPEZ:inicio -->
### LOPEZ — Verificar cargador local y ejecutar comparación L1/L4

**Responsable:** @VicuzS. **Rama:** `lopez`. **Semanas:** 11/16 y parte de 11/18 y 12/19.

**Objetivo:** demostrar con datos equivalentes y cargas nuevas cómo se comporta el pipeline local con una y cuatro goroutines de procesamiento.

**Tareas:**

1. Revisar/reutilizar el loader actual, su CLI `-workers`, validación, lotes e idempotencia. No crear otro algoritmo ni presentar la ingesta como multinodo.
2. Extender salida/instrumentación donde haga falta: tiempo total, filas de origen/s, viajes válidos/s, configuración y fases útiles. La captura de recursos se coordina con Gerardo.
3. Implementar `scripts/benchmark-load.ps1` con la interfaz acordada con Cueva: L1/L4 sobre MongoDB vacío exclusivo por ensayo, mismos datos/lotes, mismo `GOMAXPROCS` y presupuesto de CPU. Validar el destino antes de limpiar su propia base.
4. Rechazar `reused=true` y las estadísticas históricas que devuelve la ruta de reutilización. Conservar fallos sin introducir datos de la demo.
5. Ampliar solo las pruebas necesarias de equivalencia/idempotencia/rechazos. Comparar conteos, rechazo por causa, dataset ID, splits y checksum del snapshot; aceptar orden físico distinto de inserción cuando el resultado lógico es igual.
6. Tras integrar entorno/runner, ejecutar L1/L4: un calentamiento y cinco mediciones por caso, orden alternado. Registrar las condiciones reales de caché y almacenamiento.
7. Verificar de forma independiente en MongoDB viajes/ventanas y total agregado; conservar manifiestos y producir resumen bruto suficiente para recalcular estadísticas.
8. Documentar resultados y límites en `docs/BENCHMARK_CARGA.md`. Si aparece un cuello de botella, proponer un cambio acotado y repetir la comparación afectada con datos/configuración idénticos.

**Archivos:** `cmd/loader/`, `internal/loader/`, pruebas relacionadas, subscript/documento de carga y evidencia L1/L4. Las modificaciones de contrato/Compose se solicitan a Cueva.

**Dependencias:** contrato/entorno inicial de Cueva; instrumentación de recursos de Gerardo para campaña completa. Puede empezar con fixtures sin esperar al runner final. Entrega snapshot válido a las campañas de entrenamiento mediante el entorno coordinado, sin cambiar el activo de la demo.

**Criterios de aceptación:**

- [ ] L1/L4 producen datos equivalentes y `reused=false` en todas las mediciones de ingesta.
- [ ] Dataset real con más de un millón de viajes válidos, conteos/splits/checksum verificados.
- [ ] Hay calentamientos identificados y cinco muestras medidas válidas por caso; los fallos quedan preservados.
- [ ] Tiempos, throughput, configuración, recursos/cobertura y orden quedan vinculados a campaña.
- [ ] Las pruebas existentes y las afectadas pasan, incluida integración MongoDB configurada.
- [ ] Evidencia accesible, interpretación de carga local y límites documentados.
- [ ] PR desde `lopez` a `main`, revisión de Cueva y correcciones resueltas.

**Verificación:** equivalencia 1/4 goroutines e idempotencia; casos de fuente/rechazos y base/reutilización incorrecta; formato, vet, pruebas con race e integración MongoDB sobre los paquetes afectados; campaña real separada de tests.
<!-- tarea:LOPEZ:fin -->

<!-- tarea:TACO:inicio -->
### TACO — Instrumentar SGD y comprobar candidatos antes de selección

**Responsable:** @MiguelTacoZavala. **Rama:** `taco`. **Semanas:** 11/17, parte de 11/18, 12/19 y soporte de 13/21–23.

**Objetivo:** que la contraparte local y los workers TCP ejecuten SGD comparable, con fases medibles y evidencia de los candidatos reales antes de elegir persistencia u otro modelo publicado.

**Tareas:**

1. Revisar `training.Execute`, `Sequential`, CLI del trainer y flujo de maestro/workers. Reutilizar el mismo núcleo de cómputo e hiperparámetros.
2. Registrar preparación, núcleo SGD, evaluación/selección, publicación y total con semántica uniforme. Documentar qué incluye cada reloj, también carga del snapshot/inicialización de workers y arranque excluido.
3. Capturar para benchmarks los pesos/diagnósticos del candidato antes de `ml.Select`, junto con pérdida y métricas de validación. No confundirlo con el modelo publicado ni exponer información nueva innecesaria en la API pública.
4. Comparar S/D1/D2/D4 con el mismo snapshot, encoder, train/validation/test, batch global, semilla y configuración. Registrar diferencia máxima y aplicar tolerancia absoluta/relativa acordada por parámetro.
5. Añadir una prueba que detecte candidatos distintos incluso cuando ambas publicaciones elijan persistencia. Mantener pruebas de equivalencia TCP con 1/2/4 workers, duplicados, timeouts y ausencia de fuga temporal.
6. Mantener compatibilidad de artefactos existentes y publicación del modelo anterior ante fallo. Los diagnósticos de benchmarks deben quedar separados o ser opcionales con comportamiento documentado.
7. Entregar a Gerardo comandos/interfaz y salida estructurada, dimensiones, pasos y tareas esperadas para validar runs. Hacer smoke real del trainer con el entorno aislado; la campaña repetida la ejecuta Gerardo para evitar duplicarla.
8. Documentar en `docs/BENCHMARK_ENTRENAMIENTO.md` el método y límites. Atender optimizaciones/correcciones demostradas por la campaña sin cambiar el protocolo para simular speedup.

**Archivos:** `cmd/trainer/`, `internal/training/`, pruebas ML/TCP/integración necesarias. Coordinar primero con Gerardo/Cueva cualquier edición de `internal/cluster/master/` o `internal/telemetry/`.

**Dependencias:** contrato inicial de Cueva; snapshot válido para smoke real. Gerardo consume esta entrega para las campañas; no necesita esperar al informe final.

**Criterios de aceptación:**

- [ ] SGD local funciona sin parameter server y comparte datos/configuración comparables con TCP.
- [ ] Todas las fases están definidas y no se ocultan inicialización ni publicación.
- [ ] Candidatos previos a selección comparados con tolerancia registrada; modelos publicados verificados aparte.
- [ ] Una selección común de persistencia no puede ocultar una divergencia de candidatos.
- [ ] Artefactos previos, selección solo por validación y retención del modelo ante fallo siguen funcionando.
- [ ] Pruebas numéricas, TCP 1/2/4, integración, vet y race aplicables pasan.
- [ ] PR desde `taco` a `main`, revisado por Cueva, con documentación y evidencia de smoke.

**Verificación:** pruebas de candidato/publicación con datos controlados y fallo deliberado de equivalencia; tests TCP existentes y temporalidad; lectura de artefactos anteriores; smoke de ambos modos sobre el mismo snapshot sin presentar su tiempo como benchmark repetido.
<!-- tarea:TACO:fin -->

<!-- tarea:GERARDO:inicio -->
### GERARDO — Medir recursos y evaluar escalabilidad S/D1/D2/D4

**Responsable:** @Geleon515. **Rama:** `gerardo`. **Semanas:** parte de 11/18 y 12/19; 13/21–22 y ajustes de 13/23.

**Objetivo:** producir campañas reales de entrenamiento y una comparación rastreable de tiempos, speedup, eficiencia y CPU/RAM, sin presumir que distribuir acelera.

**Tareas:**

1. Implementar captura temporal en `scripts/benchmark-resources.ps1` o interfaz equivalente acordada. Combinar telemetría de procesos Go con estadísticas de contenedor, conservando métricas y alcances separados.
2. Registrar loader/trainer temporales y maestro/workers, además de MongoDB/Redis/API según el ensayo; alinear marcas de tiempo con fases de ejecución. Muestrear aproximadamente cada segundo y registrar cobertura o usar contadores adecuados si la fase es breve.
3. Agregar CPU media/máxima y RAM máxima observada del conjunto sumando muestras alineadas. No sumar máximos de momentos diferentes, no confundir RSS con heap/memoria Docker y no sustituir datos faltantes por cero.
4. Implementar `scripts/benchmark-training.ps1`: validar exactamente 1/2/4 workers conectados/sanos, sin otro run activo, y después exigir tareas aportadas por cada worker, pasos y estado completos. Integrar diagnósticos de Taco.
5. Ejecutar S/D1/D2/D4 con un calentamiento y cinco repeticiones por caso, mismo snapshot/configuración, orden rotado, servicios preparados y un `GOMAXPROCS=1` por proceso inicialmente. Registrar cuotas y presupuesto total; medir arranque separado.
6. Implementar agregaciones reutilizables acordadas con Cueva: media, mediana, mínimo, máximo, desviación muestral, speedup y eficiencia. Probar con entradas conocidas y rechazar mezclas de campañas/configuraciones incompatibles.
7. Calcular `T_S/T_Dn`, `T_D1/T_Dn` y eficiencia `(T_D1/T_Dn)/n`, usando medianas; mostrar núcleo SGD y total por separado. Incorporar recursos y tablas de carga/API entregadas por sus responsables sin volver a medirlas con otro protocolo.
8. Publicar `docs/BENCHMARK_ESCALABILIDAD.md` y tablas CSV/JSON: distinguir un host con contenedores de varios servidores; explicar memoria de snapshots replicados, costes observados y límites. Si D4 no cabe o falla, registrar causa y no declarar el caso completo.
9. Proponer ajustes sustentados por resultados. Cada propietario cambia su componente; repetir solo los casos afectados, conservar antes/después y registrar nueva versión/campaña.

**Archivos:** scripts de recursos/entrenamiento, estadísticas/agregaciones de `internal/benchmark/` en archivos acordados, documento/resultados de escalabilidad. Coordinar cambios transversales a maestro/telemetría con Taco.

**Dependencias:** contrato/entorno de Cueva; instrumentación de Taco y snapshot válido. Puede entregar captura/agregaciones con muestras controladas antes de las campañas. Las campañas se reservan por turnos con Cueva.

**Criterios de aceptación:**

- [ ] Todos los casos S/D1/D2/D4 tienen cinco mediciones válidas, calentamiento y fallos identificados.
- [ ] Cada worker requerido aportó tareas; datos, configuración y tolerancia son comparables.
- [ ] CPU/RAM por servicio y conjunto tienen unidades, semántica, cobertura y evidencia temporal.
- [ ] Tablas y fórmulas se recalculan desde evidencia accesible y no mezclan campañas incompatibles.
- [ ] Speedup menor que 1 y ausencia de mejora se publican sin alterar resultados.
- [ ] Pruebas de estadísticas/casos incompletos, vet/race e integraciones afectadas pasan.
- [ ] PR desde `gerardo` a `main`, revisado por Cueva; campaña y documentación disponibles para Vera.

**Verificación:** estadísticas con valores conocidos, denominadores inválidos, RAM faltante/desalineada, workers insuficientes y snapshots distintos; campañas reales con recursos e identidad de cada run. Entregar a Vera un cuadro verificable, no solo capturas.
<!-- tarea:GERARDO:fin -->

<!-- tarea:DRAGON:inicio -->
### DRAGON — Medir API concurrente con Redis frío, caliente y no disponible

**Responsable:** @FernanRojasR. **Rama:** `dragon`. **Semanas:** 12/20 y soporte del cuadro/ajustes de 13/22–23.

**Objetivo:** medir la experiencia HTTP de predicción con concurrencia y reportar latencia, capacidad, errores y uso real de caché.

**Tareas:**

1. Crear `cmd/benchmark-api/` en Go con bibliotecas existentes/estándar y `scripts/benchmark-api.ps1` como adaptador al runner. Consumir configuración/contrato compartidos sin cambiar innecesariamente la API de producto.
2. Autenticarse sin imprimir/persistir secretos. Construir consultas válidas del dataset/modelo aislado y hacer un smoke antes de la campaña; login y precalentamiento quedan fuera de medición.
3. Medir desde el cliente hasta leer completamente la respuesta; validar código HTTP, JSON, identidad de dataset/modelo, datos de predicción y `cache_hit`. El `latency_ms` del servidor será auxiliar, no el tiempo principal.
4. Limitar solicitudes en vuelo a concurrencia 1/10/25 y reutilizar conexiones. Declarar el modelo de generación de carga; conservar intentos fallidos y sus tiempos/status/timeouts.
5. Ejecutar caché fría con Redis aislado vacío y consultas únicas; caliente con conjunto precalentado; Redis no disponible verificando caída y respuesta fallback. Vaciar/detener únicamente Redis del benchmark, restaurarlo al terminar y registrar cualquier desviación de caché.
6. Completar por cada escenario/concurrencia tres pasadas de 1,000 solicitudes medidas: **27 pasadas y 27,000 solicitudes medidas**, más login/precalentamiento/smoke fuera de la cifra. Rotar orden y mantener suficiente inventario de claves válidas.
7. Publicar p50/p95/p99/máximo, latencias de errores, throughput de éxitos y total, conteos de errores, tasa de caché y proporción de respuestas bajo 100 ms. Usar agregaciones compartidas si ya están disponibles.
8. Reportar el criterio operativo p95 <100 ms y cero errores inesperados **por caso**, con máximo/porcentaje fuera de meta. Si no pasa, registrar incumplimiento y proponer ajuste; una prueba ejecutada no equivale a meta lograda.
9. Entregar una pasada separada por proxy web para comprobar el recorrido de la demo y documentar en `docs/BENCHMARK_API.md`; no mezclar proxy/directo o REST/WebSocket en la misma estadística.

**Archivos:** CLI/subscript/documento/resultados de API y sus pruebas. Coordinar con Cueva cambios de Compose; detener Redis mediante el contexto aislado que suministra el runner.

**Dependencias:** contrato y entorno de Cueva, dataset/modelo válido para campaña. Puede desarrollar contra servidor HTTP de prueba y entregar primero el generador. Los turnos reales no deben coincidir con carga o entrenamiento.

**Criterios de aceptación:**

- [ ] Matriz completa de tres escenarios, tres concurrencias y tres pasadas, 1,000 solicitudes cada una.
- [ ] Límites de concurrencia, conexiones, tiempo de cliente y validación de respuesta comprobados.
- [ ] Caché fría/caliente/fallback verificados en respuestas; preparación y login fuera de medición.
- [ ] Errores, timeouts, percentiles y throughput no se ocultan ni se confunden con métricas internas.
- [ ] Cumplimiento <100 ms informado por caso, incluidos máximo y proporción de exceso.
- [ ] Redis aislado restaurado, demo intacta y evidencia accesible sin secretos.
- [ ] PR desde `dragon` a `main`, revisado por Cueva; tests del generador y chequeos afectados pasan.

**Verificación:** servidor controlado para límite de concurrencia, respuestas inválidas/no-200 y timeouts; pruebas de percentiles conocidos y caché inesperada; campaña real independiente de esos tests. Repetir casos afectados tras una corrección.
<!-- tarea:DRAGON:fin -->

<!-- tarea:VERA:inicio -->
### VERA — Auditar resultados y documentar el cierre de semanas 11–13

**Responsable previsto:** @LeonardoVera. **Rama:** `vera`. **Semanas:** verificación transversal de 11–13, informe de 13/22 y regresión de 13/23.

**Estado:** borrador de issue, **no publicar ni asignar todavía**. Cueva verificará que LeonardoVera haya aceptado la invitación y tenga acceso antes de crearlo con este contenido y los enlaces de dependencia.

**Objetivo:** comprobar de forma independiente que los resultados sostienen las declaraciones de avance y explicar exactamente qué cambió frente a la versión inicial.

**Tareas:**

1. Leer el plan, este reparto y los contratos/resultados aprobados. Revisar la referencia congelada y distinguir evidencia histórica de octubre de campañas nuevas.
2. Crear `scripts/check-weeks-11-13.ps1`: exigir matriz completa, repeticiones, calentamientos identificados, datos/configuración coherentes, `reused=false`, workers con tareas, equivalencia de candidatos y estados/errores visibles.
3. Recalcular independientemente muestras representativas de tiempos, percentiles, speedup/eficiencia y recursos; trazar tablas hasta muestras originales. La falta de evidencia bruta accesible debe quedar como pendiente, no como aprobación.
4. Revisar condiciones de API, casos que exceden 100 ms, errores y si la caché observada coincide con el escenario. Comprobar que fixtures no fueron presentados como dataset real.
5. Ejecutar regresión final: formato, vet, `go test -race -count=1 ./...` con MongoDB de integración configurado, chequeos existentes de demo/semanas 7–10 y nuevo chequeo de 11–13. Verificar que las integraciones no se omitieron por faltar configuración.
6. Comprobar autenticación, predicción, Redis, WebSocket, telemetría, datos/modelo preservados y recorrido de navegador afectado. Si cambió React, compilarlo y verificarlo.
7. Elaborar `docs/SEMANA_11_13.md`: método, entorno, matriz, resultados, tablas de Gerardo, limitaciones y comparación antes/después por componente. Mostrar qué se implementó y qué solo se midió o sigue pendiente.
8. Crear `docs/VERIFICACION_SEMANA_13.json` con campaña/commit, resultados de chequeos y estado por actividad. Actualizar README y plan general solo con criterios/evidencia comprobados.
9. Mantener visibles la pregunta social, mapa, persistencia elegida, límites de un solo host y despliegue final de semanas 14–15. Los defectos detectados vuelven al responsable mediante comentarios en su issue o un issue correctivo coordinado con Cueva.

**Archivos:** chequeo final, informe/evidencia final y actualización documental de avance. No optimizar motores o cambiar datos para hacer pasar resultados durante la auditoría; solicitar la corrección al propietario.

**Dependencias:** invitación aceptada, contratos/componentes integrados y campañas de López/Gerardo/Dragon, con diagnósticos de Taco y runner de Cueva. Puede preparar checklist al tener acceso; la aprobación final requiere las evidencias.

**Criterios de aceptación:**

- [ ] Acceso confirmado e issue creado/asignado solo después de aceptar la invitación.
- [ ] Chequeo detecta muestras/casos faltantes, resultados incompatibles y evidencia insuficiente.
- [ ] Tablas contrastadas con muestras y corrección SGD previa a selección verificada.
- [ ] Regresión de Go/MongoDB/demo completa con comandos y resultados guardados.
- [ ] Informe y JSON distinguen cumplido, meta incumplida y trabajo pendiente sin inventar resultados.
- [ ] Comparación con la versión inicial y brechas históricas explícitas.
- [ ] PR desde `vera` a `main`, revisado por Cueva antes del merge; correcciones resueltas.

**Verificación:** probar el checker con evidencia incompleta deliberada y con una campaña válida; ejecutar regresión real sobre la versión final integrada y repetir lo afectado por correcciones. No certificar una instalación limpia ni otro host si no se probaron: corresponden a semanas posteriores.
<!-- tarea:VERA:fin -->

## 8. Ajustes y evidencia antes/después

La fila de ajustes finales no queda sin responsable: López corrige ingesta, Taco entrenamiento, Gerardo captura/agregación/escalabilidad, Dragon API/generador y Cueva infraestructura/orquestación. Cada corrección vuelve a su rama y se somete a PR.

Antes de cambiar una optimización, adjuntar diagnóstico y campaña de referencia; después, pruebas de corrección y repetición comparable. No exigir una aceleración artificial para cerrar el trabajo. Si no hay optimización segura justificada, documentar la conclusión y las mejoras efectivas de instrumentación/validación.

Cada responsable entrega código, pruebas, instrucciones, evidencia y limitaciones. Vera audita e informa; no tiene que reconstruir los resultados faltantes de otros integrantes. Cueva coordina y revisa; asignar la coordinación no convierte en su responsabilidad implementar todos los componentes.

## 9. Estado de publicación

- Plan técnico y reparto: documentación de trabajo, con aprobación mediante PR antes de integrarse a `main`.
- Cinco issues activos creados y asignados: enlaces registrados en la tabla de responsables.
- Vera: contenido preparado en la sección 7; issue pendiente por invitación no aceptada.
- Desarrollo, campañas, revisiones y merges: pendientes de ejecución por los responsables.
- Estimación: las 20–33 horas del plan técnico eran una aproximación de implementación individual. El reparto por sí solo no fija plazos ni reduce ese total entre seis: hay coordinación, revisión y auditoría adicionales. Estimar cada issue con su responsable al comenzar, sin inventar disponibilidad o fechas del grupo.
