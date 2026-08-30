# RUNBOOK — Muestreador de H3

**Qué decide**: si el health check TCP del NLB detecta, o no, un nodo cuyo Envoy
no sirve.

**Por qué existe**: INCIDENTS #20 declara H3 **verificada por la configuración
del target group** y nunca observada en vivo. El runbook v2
(`origin/docs/4a-v2-live-capture`, `03235e6`) diseñó un muestreador para
demostrarlo y **4a-v2 nunca se ejecutó**, así que la serie no existe. Este es
ese muestreador, con el flujo que le faltaba.

**Alcance**: solo observa. No toca el health check, ni el security group, ni
Tofu, ni despliega nada. En particular **no** construye el agregador de
`platform/node-readiness/`, que sigue sin desplegar.

---

## Qué captura, y de dónde sale cada dato

Una línea cada `INTERVAL` segundos (5 por defecto), con timestamp UTC:

| campo | qué es | origen |
|---|---|---|
| `tg=[...]` | estado de los 3 targets del TG del gateway | `aws elbv2 describe-target-health`, desde el host del operador |
| `tcp=[...]` | intento TCP real a `<ip-privada>:30443` de **cada** worker: `open` (rc 0), `closed` (rc 1, rechazado), `timeout` (rc 124, filtrado) o `ERROR:rc<N>` con su stderr | `bash /dev/tcp` en **cp-0**, vía SSM Run Command |
| `nlb=...` | qué obtiene un cliente de fuera por el NLB en `:443` | `curl` desde el host del operador |
| `ds_agent`, `ds_envoy` | `updatedNumberScheduled/numberReady` | `kubectl`, lo que ya registraba la tabla de #20 |
| `pods=[...]` | `nodeName=ready` de cada pod de `cilium-envoy` | `kubectl` |
| `iter=Ns` | cuánto tardó de verdad esa iteración | reloj local |
| `event=...` | marca del operador (`kill -STOP`, `kill -CONT`) | subcomando `mark` |

**Cada campo lleva su propio timestamp** (`tg@...`, `tcp@...`, `nlb@...`,
`ds@...`), no la fila. Una ronda puede tardar hasta ~12 s por la ida y vuelta de
SSM: una fila estampada una sola vez presentaría como simultáneos estados que
**nunca coexistieron**.

`meta` incluye el **mapa de identidades** `instance-id ↔ IP privada ↔ nodeName`.
Sin él los tres flujos son incruzables: `tg=` habla de instance-ids, `tcp=` de
IPs privadas y `pods=` de nodeNames.

### Por qué el TCP no se mide desde el portátil

El SG de workers admite 30443 **solo desde el SG del NLB**
(`tofu/modules/worker/main.tf:41-47`). Desde fuera está cerrado **por diseño**,
y el smoke lo afirma como prueba negativa: *«NodePort closed on EVERY worker
public IP»*. Un intento desde el portátil mediría el cortafuegos, no el
datapath. Por eso el sondeo sale de un control plane, cuyo SG sí tiene paso
hacia los workers.

### Por qué `iter` está en la serie

Cada iteración paga una ida y vuelta de SSM Run Command (~2-4 s), así que la
cadencia real no es exactamente 5 s. **El intervalo conseguido es un dato de la
serie**, no una suposición del lector.

### Fail-closed

Cada campo es un valor medido o `ERROR:<motivo>`. No hay defaults, ni cadenas
vacías haciendo de lectura, ni ninguna rama que convierta «no pude medir» en un
valor plausible. Un hueco es un dato; un cero inventado es mentira — y este
ejercicio existe precisamente porque un health check contestó sin mirar.

En particular: **un fallo de herramienta en el host de sondeo es `ERROR`, nunca
`closed`.** `closed` es un hallazgo sobre el datapath y no puede fabricarlo un
binario ausente. Y las respuestas **parciales** son `ERROR`: menos de una
entrada por worker en `tcp=`, o menos targets de los esperados en `tg=`, no son
una lectura parcial del cluster sino una lectura rota de la sonda.

---

## Cómo se corre

```
AWS_PROFILE=k8s-vanilla-lab make kubeconfig
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
AWS_PROFILE=k8s-vanilla-lab bash scripts/sample-h3.sh
```

Escribe en `/tmp/h3-<timestamp>/`:

- `series` — una línea por muestra, el fichero que se lee
- `meta` — resolución inicial (TG, DNS del NLB, IPs de workers, host de sondeo)
  y las marcas de arranque y parada
- `trace` — la traza de `set -x`, para depurar el muestreador, no el cluster

Se para con `Ctrl-C`. Arrancarlo **antes** de provocar el fallo y dejarlo
correr hasta después de la recuperación.

### Marcar el corte y la reanudación

Sin estas dos marcas la serie no tiene origen y ningún tramo se puede situar.
Desde otra terminal, **en el mismo instante** de cada acción:

```
bash scripts/sample-h3.sh mark "kill -STOP cilium-envoy i-0abc 10.0.1.10 ip-10-0-1-10"
bash scripts/sample-h3.sh mark "kill -CONT cilium-envoy i-0abc 10.0.1.10 ip-10-0-1-10"
```

**Identifica el worker intervenido con las tres identidades** — instance-id, IP
privada y nodeName — porque cada campo de la serie usa una distinta. El mapa
está en `meta`.

`mark` falla si no hay muestreador corriendo: no escribe una marca huérfana en
ningún sitio.

---

## Cómo se lee

La línea que decide H3 es aquella en la que, para el worker intervenido:

```
tcp=[<ip>=open ...]   y   tg=[<id>=healthy ...]   y   nlb=ERROR:curl-rcN
```

### La ventana: los primeros ~95 s son CIEGOS

El health check corre con los defaults de AWS: `interval=30s`,
`unhealthy threshold=3`. Un target tarda **hasta 95 s** en pasar a `unhealthy`
**aunque el check sí detecte el fallo** — 3 comprobaciones fallidas, la primera
hasta 30 s después del corte, más el tiempo de propagación del estado.

Por tanto:

| tramo desde `event=kill -STOP` | valor probatorio |
|---|---|
| **0 → ~95 s** | **CIEGO.** `tg=healthy` aquí es lo que se vería igualmente si H3 fuera falsa. No demuestra nada |
| **~95 s → ~270 s** | **VENTANA ÚTIL.** El umbral ya pudo cruzarse; si no lo hizo, es un dato |
| **> ~270 s** | contaminado: el `livenessProbe` reinicia el contenedor y el datapath cambia |

Sin las marcas de `kill -STOP` y `kill -CONT` en la serie no se puede situar
ningún tramo. Por eso el muestreador tiene subcomando `mark`.

### Tabla de lectura

Las tres filas se evalúan **solo dentro de la ventana útil**.

| lectura | qué significa |
|---|---|
| `tg=healthy` + `tcp=open` en el worker intervenido + `nlb=http5xx` | **H3 confirmada en vivo**: el health check no ve el fallo, el NodePort sigue aceptando, y el cliente recibe un error **que el NLB devolvió** |
| `tg=unhealthy` en el worker intervenido | **NO CONCLUYE** — ver el límite más abajo |
| `tcp=closed` o `tcp=timeout` en ese worker | el fallo provocado tumbó también el datapath: **el experimento no aisló Envoy** y no dice nada sobre H3 |
| cualquier `ERROR:` en la fila | **la fila se descarta entera.** Un campo que no se leyó no se sustituye por lo que se esperaba, y una fila con un hueco no sostiene una conclusión sobre las demás |

### La evidencia del fallo de servicio tiene que ser POSITIVA

`nlb=ERROR:curl-rcN` **no vale como demostración**. Es ausencia de lectura: no
distingue «el NLB no sirvió» de «el portátil perdió la red», «DNS falló» o
«el `curl` agotó su timeout por carga local». Sirve como señal positiva:

- `nlb=http5xx` — un código que **el NLB devolvió**, o
- el testigo (`scripts/witness-traffic.sh`) desde otro origen, con su veredicto.

`nlb=` mide el efecto agregado de los tres nodos: con dos de tres sirviendo,
parte de las peticiones seguirá saliendo bien. Lo relevante no es que falle
siempre, sino que falle **mientras el TG dice `healthy`**.

### EL LÍMITE: la rama `unhealthy` no refuta H3

Si el TG pasa a `unhealthy`, este experimento **no puede distinguir dos causas**:

1. el health check TCP **detectó** el fallo de Envoy — H3 sería falsa; o
2. la **cola de accept se saturó**. `SIGSTOP` no cierra el socket de escucha:
   el kernel sigue completando handshakes y encolando. Si el tráfico real llena
   esa cola, el kernel empieza a descartar SYN y el health check falla **por
   saturación**, no por detección.

Ambas producen la misma serie. Por tanto: **el experimento confirma H3 o no
concluye. No la refuta.** Refutarla exigiría un diseño que controle la cola de
accept, que no es este.

---

## Método de fallo — PROPUESTO, NO APROBADO

> Pendiente de aprobación de dirección. **No ejecutar** hasta entonces.

**Propuesta: `kill -STOP` al proceso `cilium-envoy` de UN worker, vía SSM Run
Command.**

Es la condición exacta que H3 predice invisible: Envoy deja de servir y **el
agente sigue vivo**, así que sigue programando el NodePort.

Qué NO toca: ningún objeto de Kubernetes, ninguna release de Helm, ningún SG,
ningún target group. El pod no se borra ni se reprograma.

Ventana, según los probes del chart 1.20.1 (`envoy.livenessProbe`
`failureThreshold: 10` × `periodSeconds: 30`; `readinessProbe` `3` × `30`):

| desde el corte | estado |
|---|---|
| 60 → 90 s | el pod pasa a `NotReady`. **Es un rango, no un valor**: el corte cae en un punto arbitrario del ciclo de 30 s, así que el primer probe fallido llega entre 0 y 30 s después, y los otros dos a +30 y +60 |
| 270 → 300 s | el kubelet mata y reinicia el contenedor. **Recuperación automática**: el radio de daño está acotado por el propio chart |

`timeoutSeconds: 5` importa: con Envoy parado el socket sigue abierto, así que
el probe del kubelet **no recibe connection-refused, se cuelga** hasta agotar
esos 5 s antes de contar como fallo.

Estos rangos son del **pod**, y no deben confundirse con la ventana probatoria
del **target group**, que son otros ~95 s por una causa distinta (`3 × 30 s` del
health check). Coinciden en magnitud y no tienen relación.

Reversión inmediata: `kill -CONT` al mismo PID.

Cuidado al elegir el PID: hay dos procesos, `cilium-envoy-starter` (padre) y
`cilium-envoy` (hijo). **Hay que parar el hijo**; parar solo el padre deja a
Envoy sirviendo.

### Alternativas consideradas y por qué no

| método | por qué se descarta |
|---|---|
| borrar el pod de Envoy | la ventana dura segundos y modifica un objeto de Kubernetes |
| parchear el DaemonSet (`nodeSelector`, réplicas) | objeto gestionado por Helm: introduce deriva, y afecta a todos los nodos, no a uno |
| `taint` del nodo | los DaemonSets toleran la mayoría de taints; no desalojaría el pod |
| `crictl stop` del contenedor | el kubelet lo reinicia de inmediato: ventana demasiado corta |
| bloquear `:443` con iptables en el nodo | no reproduce «Envoy caído» y altera el cortafuegos del nodo |

---

## Qué NO demuestra esta pieza

Mide **una** afirmación: si el health check ve el fallo. No mide la causa de
#20 (por qué el Envoy 1.37.5 no servía, declarada **NO CONOCIDA** y con los
logs perdidos), ni H2 (si el listener xDS llega tarde), ni valida el agregador
de readiness, que sigue sin desplegar y sin enunciado probado.
