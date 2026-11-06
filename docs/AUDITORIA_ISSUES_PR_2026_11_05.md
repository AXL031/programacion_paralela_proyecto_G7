# Auditoría de issues y PR — 5 de noviembre de 2026

**Actualización posterior al cierre técnico:** código de issues1–5 integrado en main mediante PR #14/#15, con autorización expresa del usuario y CI verde; 63 muestras originales y bruto verificable en el [cierre de desarrollo](CIERRE_DESARROLLO_11_13.md). Las campañas se identifican por fase y conservan los fallos anteriores. La auditoría independiente y los documentos/checker de Vera siguen en #8. El estado previo de este documento se conserva como historia; no representa pendientes de código actuales.


Revisión de GitHub, código, checks y evidencia publicada. Referencias auditadas: `main` **c464ebf794d370256ffa362192e1ee8d9ad42df3**, PR #11 **8244c1d77be363dc4690e1356a9e4055e3a970ae** y PR #12 **c0487fce37587b05419a5cb22a6adace03639bca**. Los dictámenes corresponden a esas revisiones, no a commits posteriores.

**Dictamen:** #11 requiere corregir la retención de evidencia por muestra y resolver la revisión antes de merge. #12 se abrió en borrador y requiere cambios de aislamiento, contrato y protocolo. #7, #9 y #10 ya están fusionadas como entregas parciales; eso no cierra sus issues ni certifica las semanas 12–13. Se detectó además un defecto compartido de validación de candidatos que debe corregirse antes de certificar entrenamiento.

## Hallazgos que requieren acción

| Prioridad | Componente | Hallazgo y consecuencia | Corrección necesaria |
|---|---|---|---|
| P1 | #1/#3, runner y diagnósticos de #10 | `cmd/trainer/main.go:124–133` admite `SetSelfReference` para un candidato distribuido sin referencia. `internal/training/diagnostics.go:192` no exige que la referencia sea secuencial. `scripts/benchmark/common.psm1`, validación de entrenamiento, compara arrays y checksum sin acreditar modo/run/dataset/snapshot/encoder de la referencia. Una prueba negativa sintética fue **aceptada** usando el mismo run distribuido como referencia y un dataset/snapshot ajeno. Esto permite certificar una equivalencia S/D que nunca se comprobó. | Exigir referencia S para Dn; validar identidad, modo, run, snapshot, encoder, splits e hiperparámetros contra el diagnóstico secuencial real de la campaña. Rechazar autorreferencias y probar estos casos negativos. No hay evidencia de que las mediciones reales de ingesta estén afectadas. |
| P1 | Dragon #12 | Los scripts no reciben `ContextPath/SamplePath/OutputPath` ni producen muestras `benchmark-v1`. `benchmark-training.ps1:266` detiene/escala servicios del Compose de la demo y su `finally` vuelve a detener maestro/workers/MongoDB. `benchmark-api.ps1:175–209` usa la web y la sesión de la demo. | Consumir exclusivamente proyecto, credenciales, puertos y rutas del entorno aislado de #1. Integrar recursos de #4 y conservar/verificar demo antes/después. Una base de otro nombre no aísla los servicios. |
| P1 | Dragon #12 | API ejecuta dos pasadas (`initial_pass`/`replay_pass`, línea 397), sin garantizar frío ni probar Redis caído, con 300 peticiones y concurrencia 8 por defecto. Entrenamiento compara pesos **publicados** (línea 318), que pueden ser persistencia, y solo calienta S. | Completar 3 estados Redis × concurrencia 1/10/25 × 3 pasadas × 1.000 solicitudes; probar miss/hit/fallback y restauración. Usar candidatos previos a selección de #10, calentamiento por caso y matriz compartida. |
| P2 | López #11 | `benchmark-load.ps1:373,565,808` usa prefijos fijos `load-reset`, `load-preflight`, `load-verify`. El helper escribe los logs con reemplazo. El ZIP conserva **un solo** resultado independiente de MongoDB, correspondiente al último load ID; los otros once fueron sobrescritos. Los logs del loader y recursos sí se conservan por muestra. | Incluir `sample_id` en los tres prefijos, conservar reset/verificación por muestra y añadir una prueba de retención con dos muestras. Regenerar la evidencia independiente que falte o declarar expresamente el alcance parcial; no reconstruir logs históricos inventados. |
| P2 | López #2, aceptación de campaña | El manifiesto publicado está en `prepared`, `samples=[]`; las 12 invocaciones fueron directas al adaptador, fuera de `Run`, como reconoce el documento. La preservación indica `mongo_observed=false`: se contrastaron 9 archivos, no MongoDB ni funcionamiento de la demo. El fallo previo solo se conserva en la PC del autor. | Registrar un manifiesto explícito de **campaña parcial de ingesta**, orden, invocaciones y estados; proporcionar el comando/script exacto de reproducción y el fallo previo compartible. Completar la comprobación de preservación y regresión final. No marcar la campaña completa de 63 muestras como aprobada. |

## PR y aptitud para integración

| PR | Estado observado | Evaluación |
|---|---|---|
| [#7 — Cueva](https://github.com/AXL031/programacion_paralela_proyecto_G7/pull/7) | Fusionada | Base aislada y runner implementados, con smoke y evidencia histórica de esta entrega. Aceptable como base parcial; el hueco de candidatos requiere corrección en #1/#3 antes de certificar entrenamiento. |
| [#9 — Gerardo](https://github.com/AXL031/programacion_paralela_proyecto_G7/pull/9) | Fusionada | Colector, estadísticas y resumen implementados. Se reprodujeron **45 checks** offline. La evidencia de #11 también contiene captura real del colector. Faltan adaptador de entrenamiento, campañas y tablas reales S/D1/D2/D4. No se detectó otro bloqueo de código en el alcance inspeccionado. |
| [#10 — Taco](https://github.com/AXL031/programacion_paralela_proyecto_G7/pull/10) | Fusionada | Captura preselección, tiempos y endpoint interno implementados; CI Go/React verde. El guard de referencia descrito arriba requiere corrección. Faltan smoke aislado con diagnósticos y campañas repetidas. |
| [#11 — López](https://github.com/AXL031/programacion_paralela_proyecto_G7/pull/11) | Abierta, sin conflictos; Go/React verdes | **Solicitar cambios antes de merge:** retención de verificaciones MongoDB por muestra y cierre de revisión. Los resultados de tiempos son recalculables y constituyen avance real. No cerrar #2 mientras falten las evidencias de aceptación. |
| [#12 — Dragon](https://github.com/AXL031/programacion_paralela_proyecto_G7/pull/12) | Abierta en borrador por esta auditoría | **No apta para merge.** Tiene una implementación inicial útil, pero requiere adaptar aislamiento, interfaces, matriz, candidatos y pruebas. No cierra #5. |

Las revisiones de GitHub consultadas para #9, #10 y #11 están vacías. En #9/#10 no consta una aprobación formal independiente aunque ya se fusionaron; una decisión previa por fuera de GitHub no se puede verificar con estos datos. El flujo acordado exige revisión independiente, conversaciones resueltas y checks aplicables. `MERGEABLE` solo acredita ausencia de conflictos.

## Qué está desarrollado y qué falta por responsable

| Issue | Avance comprobado | Falta para cerrar |
|---|---|---|
| [#1 — Cueva](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/1) | #7 en main: aislamiento, contrato, runner y smoke. #9/#10 también están integradas. | Fortalecer identidad/referencia de candidatos; integrar carga #11, API #12 y adaptador de entrenamiento; smoke conjunto, turnos, evidencia y revisión final. El adaptador de entrenamiento de Dragon no sustituye todavía el contrato de Gerardo. |
| [#2 — López](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/2) | #11: carga estricta, fases/throughput, tests de equivalencia y **12 muestras reales**, con 1.348.665 viajes aceptados por corrida y snapshot común. | Corregir logs, documentar campaña parcial reproducible, compartir fallo previo, completar preservación/regresión y revisión/merge. |
| [#3 — Taco](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/3) | #10 en main: diagnósticos SGD, fases, comparación por parámetro y endpoint protegido. | Corregir aceptación de referencia distribuida/autorreferencia, ampliar pruebas negativas, ejecutar smoke aislado con diagnósticos y verificar integración con #4. |
| [#4 — Gerardo](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/4) | #9 en main: colector CPU/RSS y contenedor, estadísticas, resumen y 45 checks offline. Captura real visible en ZIP de #11. | `benchmark-training.ps1` compatible, S/D1/D2/D4 (1 calentamiento + 5 mediciones por caso), participación exacta, candidatos, capacidad/cobertura D4 y tablas CPU/RAM/speedup/eficiencia. |
| [#5 — Dragon](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/5) | Rama y #12 con preflight, scripts de ingesta/entrenamiento y generador HTTP concurrente por proxy. | Resolver hallazgos; reutilizar carga de López; entregar generador/adaptador con contrato y pruebas; ejecutar 27 pasadas/27.000 solicitudes reales y ensayo proxy separado. No hay evidencia real versionada de esta rama. |
| [#8 — Vera](https://github.com/AXL031/programacion_paralela_proyecto_G7/issues/8) | Acceso y asignación confirmados. No se observó PR ni commits exclusivos de `vera` frente a main. | Checker de semanas 11–13, pruebas negativas, auditoría independiente de bruto/tablas, regresión Go/MongoDB/demo, informe y JSON final. Puede empezar checklist y pruebas negativas ahora. |

Los seis issues permanecen abiertos. No se cierran semanas por tener scripts ni por fusionar entregas parciales.

## Verificación y límites

- Estado, cuerpos, comentarios y checks consultados directamente con GitHub CLI. Se preservó una copia en `output/audit-2026-11-05/` (local, no versionada).
- `main`: **45 checks de Gerardo y 40 del runner aprobados**, con fixtures sintéticos. No son resultados de rendimiento.
- Evidencia de #11: **54 comprobaciones independientes** de cantidad de muestras, calentamientos, load IDs únicos, snapshot común, conteos, SHA-256 de recursos, cobertura y correspondencia con logs de loader. Los hashes de las fuentes efectivas coinciden con la PR al considerar LF/CRLF. SHA-256 del ZIP: `93f121f3715b93ea07bb7e8082dd0230127eaded5323b01f565a3027b62740c0`.
- Medianas recalculadas: total **L1 28,937116996 s / L4 26,412594908 s = 1,095580237×**; cómputo **20,608213258 / 18,371795782 = 1,121731022×**. Son resultados de ingesta local en el host del autor. La hipótesis de cuello de botella de E/S no queda demostrada solo por esos tiempos.
- Sintaxis PowerShell de las fuentes combinadas `main` + #11 y de Dragon: sin errores. No se modificó la rama local `cueva` ni se incorporaron cambios de código remotos al checkout de trabajo.
- Validación con fuentes combinadas `main` + #11: el runner aceptó **12/12 muestras de carga archivadas**, con los recursos del ZIP y su schema/checksum. Esto comprueba compatibilidad del formato; no reejecuta el adaptador ni subsana la falta de logs MongoDB históricos.
- Prueba negativa de candidatos: el runner aceptó una autorreferencia distribuida con dataset/snapshot ajeno. Resultado guardado localmente en `candidate-guard-verification.json`; es un fallo de validación, no entrenamiento ejecutado.
- CI existente: formato, vet, `go test -race -count=1 ./...` con `MONGO_TEST_URI` y build React. No incluye las suites PowerShell ni certifica campañas de rendimiento.
- La CI de la nueva PR #12 terminó **verde** (Go y React), también para el merge de prueba contra main. Sus bloqueos de protocolo/aislamiento siguen vigentes.
- Docker Linux no responde en esta sesión y Go no está en PATH: no se reejecutaron Go/MongoDB, smoke Docker ni recorrido de navegador. Sus resultados remotos y los históricos se distinguen de las pruebas locales de auditoría.
- La pregunta social, mapa, mejora predictiva y despliegue final de semanas 14–15 siguen pendientes. No hay speedup nuevo de entrenamiento ni cumplimiento demostrado de API bajo la matriz acordada.

## Siguiente integración

1. Corregir guard de referencia SGD en #1/#3 y retención de logs en #11.
2. Revisar/integrar la entrega de carga y actualizar ramas desde main sin borrar trabajo.
3. Adaptar #12 al entorno aislado y al contrato; coordinar el adaptador S/Dn con Gerardo.
4. Ejecutar smoke conjunto y campañas por turnos; entregar bruto y manifiestos parciales/completos correctamente identificados.
5. Vera audita, ejecuta regresión final y actualiza el cierre por actividad con evidencia.
