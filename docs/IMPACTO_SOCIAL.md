# Pregunta de impacto y alcance de los datos

## Pregunta definida

¿Cómo anticipar la actividad de viajes registrada por zona e intervalo para apoyar la planificación del transporte?

El usuario puede explorar 263 zonas, comparar horarios y consultar la estimación del siguiente intervalo de 15 minutos con su referencia temporal. La reproducción histórica permite contrastar cada resultado con viajes observados sin usar el objetivo futuro como entrada del modelo.

## Uso propuesto

La herramienta podría ayudar a responsables de movilidad y operadores a estudiar actividad por zona y hora, preparar decisiones de asignación y evaluar qué pronósticos son útiles. El panel por distrito resume viajes aceptados del mismo dataset, evitando sumar períodos distintos o presentar valores simulados.

Ese beneficio es una propuesta operativa. No se ha demostrado ahorro de tiempo, reducción de espera, mejora de cobertura ni impacto social causal. Antes de usarlo para tomar decisiones se requiere validar representatividad, calidad por zona y criterios con responsables de transporte.

## Fuente y límites

Yellow Taxi de NYC TLC, enero de 2024, selección del 1 al 15 de enero. Se aceptan 1,348,665 registros de viajes completados con reglas de fechas, catálogo, duración y distancia. Los rechazos quedan contabilizados. La cobertura es la de registros aceptados de este archivo, no toda la movilidad de Nueva York.

No se puede inferir demanda no atendida a partir de pocos viajes: podrían reflejar poca demanda, poca oferta o cobertura insuficiente de la fuente. El dataset no aporta todas las solicitudes rechazadas/canceladas, disponibilidad de vehículos ni atributos suficientes para atribuir desigualdad social. Las barras por distrito describen el archivo; no representan un ranking de necesidad de transporte.

Las zonas sin registros aceptados reciben cero únicamente dentro de la rejilla temporal cubierta. El cero no significa que ninguna persona haya necesitado desplazarse.

## Evaluación que acompaña a la demo

Splits temporales, normalizadores ajustados solo en train, elección de modelo solo con validación y evaluación en test. La referencia repite el conteo anterior. En la selección de quince días el candidato SGD no pasó el criterio de mejora y se publicó persistencia explícitamente. Esto evita prometer calidad que no está demostrada.

## Para estudiar demanda no atendida

Se necesitan registros de solicitudes no completadas, medidas de oferta disponible y definiciones consistentes de zona/período. Para evaluar equidad se requerirían fuentes demográficas adecuadas, un criterio explícito y análisis de cobertura. Incorporarlas cambiaría la pregunta y el contrato de datos; no debe sustituirse esa evidencia con los conteos actuales.

Fuente pública: [portal oficial de registros TLC](https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page). Archivos y huellas utilizados: `configs/sources.json`. La API `/api/v1/impact` y la sección Impacto comunican estas mismas definiciones.
