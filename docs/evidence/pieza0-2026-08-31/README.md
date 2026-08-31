# Pieza 0 — coronación: el TG detecta un Envoy muerto

**2026-08-31.** Contraprueba directa de [INCIDENTS #20](../../INCIDENTS.md).
El 31-ago por la mañana, con health check **TCP** contra el NodePort, se
midieron 22 muestras consecutivas con el target `healthy` mientras Envoy estaba
parado ([h3-2026-08-31](../h3-2026-08-31/)). Esta es la misma intervención
contra el health check **HTTP** nuevo, apuntando al agregador `node-readiness`.

## Criterio, escrito ANTES de ejecutar

1. El nodo intervenido pasa a `unhealthy` dentro de los ~20-30 s del umbral
   configurado (`interval=10` × `unhealthy_threshold=2`).
2. Los otros dos siguen `healthy` todo el rato.
3. Si caen los tres, es un fallo del agregador y **no** una detección.
4. Si el intervenido sigue `healthy`, el agregador no sirve.

## Resultado

| hito | UTC | fuente |
|---|---|---|
| `kill -STOP` sobre pid 3474 (`cilium-envoy`) | **13:36:26Z** | marca del propio nodo |
| última muestra `healthy` del intervenido | 13:36:45Z | `describe-target-health` |
| primera muestra `unhealthy` | **13:36:50Z** | `describe-target-health` |
| `kill -CONT` | 13:38:06Z | marca del propio nodo |
| vuelta a `healthy` | 13:38:28Z | `describe-target-health` |

- **Detección: entre 19 s y 24 s.** El intervalo es abierto porque el muestreo
  es cada ~5 s: lo que está probado es que ocurrió *después* de 13:36:45Z y
  *no después* de 13:36:50Z. Cae dentro del umbral configurado.
- **Recuperación: entre 17 s y 22 s**, coherente con `healthy_threshold=2`.
- **Los dos nodos de control: `healthy` en las 34 muestras.** Ninguna
  oscilación. Por eso esto es una detección y no una caída del agregador.
- Tras el `CONT`, `ps` devuelve `3474 Sl cilium-envoy` — estado `S`, no `T`.

Los cuatro criterios se cumplen.

## Lo que esta prueba NO demuestra

Mató a **Envoy**, igual que H3. El agregador **le pregunta al agente si está
bien**, así que un agente que se reporta sano con su propio datapath roto
sigue sin detectarse. Ese límite queda abierto y consignado en
[CLUSTER.md](../../CLUSTER.md) §5; cerrarlo exige una sonda que atraviese el
datapath en vez de preguntarle a quien lo programa.

## Método

SSM Run Command **autolimitado**: el nodo hace `STOP`, duerme 100 s y hace
`CONT` él solo. Así Envoy se recupera aunque el operador pierda la sesión —
un `STOP` que dependa de que vuelva un humano es un incidente esperando a
pasar. 100 s queda holgadamente por debajo de los 270 s tras los cuales el
agente de Cilium toma medidas por su cuenta.

Ficheros: [`meta`](meta) (identidades, configuración, CommandId),
[`series`](series) (las 34 muestras).
