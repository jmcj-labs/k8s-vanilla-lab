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
| `tcp=[...]` | intento TCP real a `<ip-privada>:30443` de **cada** worker | `bash /dev/tcp` en **cp-0**, vía SSM Run Command |
| `nlb=...` | qué obtiene un cliente de fuera por el NLB en `:443` | `curl` desde el host del operador |
| `ds_agent`, `ds_envoy` | `updatedNumberScheduled/numberReady` | `kubectl`, lo que ya registraba la tabla de #20 |
| `pods=[...]` | `nodeName=ready` de cada pod de `cilium-envoy` | `kubectl` |
| `iter=Ns` | cuánto tardó de verdad esa iteración | reloj local |

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
número. Un hueco es un dato; un cero inventado es mentira — y este ejercicio
existe precisamente porque un health check contestó sin mirar.

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

---

## Cómo se lee

La línea que decide H3 es aquella en la que, para el worker intervenido:

```
tcp=[<ip>=open ...]   y   tg=[<id>=healthy ...]   y   nlb=ERROR:curl-rcN
```

| lectura | qué significa |
|---|---|
| TG `healthy` + TCP `open` + NLB fallando | **H3 demostrada en vivo**: el health check no ve el fallo, el NodePort sigue aceptando, el cliente no recibe servicio |
| TG pasa a `unhealthy` | **H3 refutada**: el health check sí lo detecta. Anotar en qué segundo respecto al corte |
| TCP `closed` en ese worker | el fallo provocado tumbó también el datapath: **el experimento no aisló Envoy** y no dice nada sobre H3 |
| cualquier `ERROR:` en la ventana | ese campo **no se leyó**; no se sustituye por lo que se esperaba |

`nlb=` mide el efecto agregado de los tres nodos: con dos de tres sirviendo, una
parte de las peticiones seguirá saliendo bien. Lo relevante no es que falle
siempre, sino que falle **mientras el TG dice `healthy`**.

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
| 0 → ~90 s | Envoy parado y **el pod sigue `Ready`**. Es el tramo más nítido: si el TG sigue `healthy` aquí, no hay excusa de propagación |
| ~90 → ~300 s | el pod pasa a `NotReady`. El TG apunta a **instancias**, no a pods: comprobar si algo cambia |
| ~300 s | el kubelet mata y reinicia el contenedor. **Recuperación automática**: el radio de daño está acotado por el propio chart |

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
