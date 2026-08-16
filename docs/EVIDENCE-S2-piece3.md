# Evidencia de coronación — S2 pieza 3 (HA del control plane)

**Fecha**: 2026-08-16 · **ADR**: [ADR-007](decisions/ADR-007-api-endpoint-nlb.md) ·
**PRs**: #65 (5 cruces, merge `032d865`) + **#66** (cierre: acceso OOB + evidencia, 2 cruces)

Criterio de coronación del brief #S2-3, con la evidencia de cada punto.

**Estado: 7 de 7 criterios de aceptación cerrados.** El coste real medido
(§8) NO es un criterio de aceptación: es un dato **diferido a propósito**
porque Cost Explorer publica con ~24 h de retraso, y consta como tal aquí en
vez de fingir que no falta. Mientras llega, §8 lleva el desglose por
concepto sobre el inventario real.

---

## 0. Precondición: el guard rechazó el state real (no un fixture)

Antes de destruir, el guard corrió contra el state vivo de la pieza 2:

```
✗ recreate guard: this state still holds the PRE-HA control plane.
Legacy resources found in state:
    module.control_plane.aws_eip.control_plane
    module.control_plane.aws_eip_association.control_plane
    module.control_plane.aws_instance.control_plane
    module.control_plane.aws_vpc_security_group_ingress_rule.api_server["0.0.0.0/0"]
exit=1
```

Los cuatro recursos legados nombrados uno a uno, incluida la regla 6443 al
mundo. **La migración in-place es imposible de ejecutar por accidente.**

Estado del bucket persistente antes del destroy (debe sobrevivir):
**90 objetos** — `etcd/` 8, `cnpg/` 82 · generación CNPG registrada:
`logistics-pg-20260816t120654z`.

---

## 1. Muerte del cluster de la pieza 2

Destroy vía workflow ([run 31953737047](https://github.com/jmcj-labs/k8s-vanilla-lab/actions/runs/31953737047)), **success**. Verificación posterior:

| Comprobación | Resultado |
|---|---|
| Instancias del cluster vivas | **0** |
| NLB | `LoadBalancerNotFound` (desaparecido con el cluster, como se diseñó) |
| Volúmenes EBS dinámicos con tag `k8s-cluster` | **0** (cero huérfanos) |
| Parámetros SSM `/k8s/k8s-vanilla-lab/*` | **0** |
| **Bucket persistente de backups** | **90 objetos — INTACTO** |
| **SSM persistente** (`cnpg-server-name`) | `logistics-pg-20260816t120654z` — INTACTO |

La separación de ciclos de vida de la pieza 1 vuelve a sostenerse: lo efímero
muere entero, la cadena restaurable sobrevive.

## 2. Nacimiento HA desde estado vacío

[run 31954021824](https://github.com/jmcj-labs/k8s-vanilla-lab/actions/runs/31954021824) ·
66 recursos · NLB fresco `k8s-vanilla-lab-gw-nlb-ccd407a2916738a0`.

Los 3 CPs con joins **secuenciados**, verificado por el gate: al terminar,
`/k8s/k8s-vanilla-lab/cp/joined-count = 3` (CP-0 lo abre en 1, cada join
publica su incremento). 6/6 nodos Ready.

### Veredicto del fail-open: NO se materializa (tradeoff cerrado)

Del log de CP-0, leído **sin SSH** (pod privilegiado, patrón de la casa):

```
14:59:20  ✓ NLB DNS resolves
14:59:21  ✓ Registered in the API target group (i-0735a5deee16b3102) — the endpoint routes here
14:59:21  Step 3/9: Running kubeadm init
14:59:42  ✓ kubeadm init completed successfully          ← 21 segundos
15:00:41  Step 9/9: Opening control-plane join gate (cp/joined-count = 1)
```

**Cero** errores de conexión, timeouts o reintentos en toda la fase de init
(`grep -icE "connection refused|connection reset|timeout|retry|error|dial tcp"`
sobre las líneas del init → `0`). La razón está en el propio log: kubeadm
espera contra **`127.0.0.1`** (`kubelet-check ... http://127.0.0.1:10248/healthz`,
`control-plane-check ... https://127.0.0.1:10257/healthz`), **no** contra
`controlPlaneEndpoint`. El endpoint solo lo usan los *joins* y los clientes,
y para entonces CP-0 ya está healthy y el NLB ya no está en fail-open.

**Conclusión: no hace falta escalonar los attachments.** El gate de registro
en el TG sigue siendo necesario por lo que sí garantiza (que el endpoint
pueda enrutar a este nodo), pero la intermitencia temida no ocurre.

### Incidencia del apply: flake de red, no diseño

El paso `Install platform layer` falló en el 7/12 descargando el chart de
Strimzi (`release-assets.githubusercontent.com ... read: connection reset by
peer`). El cluster ya estaba sano; `make platform` es idempotente y completó
los 12/12 al reintentar. Misma familia que el 502 de Docker Hub del 15-ago:
descargas de terceros en el camino crítico.

## 3. Smoke completo con §14

**Verde de principio a fin**, cerrando con `✓ Smoke test passed: cluster,
platform, IAM, network, data, registry, app contract, backups, NLB entry and
HA control plane are healthy`. La sección nueva:

```
✓ 3/3 control-plane nodes Ready
✓ etcd: 3/3 members started (stacked quorum)
✓ API targets: exactly the 3 control planes, ALL healthy
✓ negative proof: :6443 closed on EVERY CP public IP (NLB is the only API door)
✓ endpoint coherence: kubeconfig + Cilium on the NLB DNS · authenticator 3/3
```

### Bug encontrado en la propia §14e (y corregido en vivo)

La primera pasada falló: `Cilium k8s-service-host is , want <NLB DNS>`. La
asertación miraba una clave del ConfigMap `cilium-config` que **no existe en
Cilium 1.19** — de haberla dado por buena, habría fallado siempre sin
haberse validado nunca. El endpoint vive como variable de entorno
`KUBERNETES_SERVICE_HOST` en los contenedores del DaemonSet, y su valor
efectivo era correcto desde el principio (comprobado dentro del agente vivo).

La comprobación corregida es **más fuerte** que la original: exige el valor
en el spec del DaemonSet **y** dentro del agente en ejecución — un spec
actualizado sin rollout leería como conforme mientras los agentes vivos
siguen hablando con el endpoint viejo.

### Nota operativa: el smoke no es idempotente en la capa de datos

Ejecutarlo dos veces seguidas cortó el segundo pase: la suite provoca un
**failover real de CNPG** y **mata un broker de Kafka** en cada ejecución, y
la capa de datos necesita asentarse entre pases. El cluster quedó sano
(6/6 nodos, CNPG 3/3, Kafka 3/3, ningún pod fuera de Running). No es un
defecto a corregir — es la naturaleza de un smoke que prueba resiliencia de
verdad —, pero conviene no encadenarlos.

## 4. Drill de pérdida: parar CP-0 (el fundador) — **SUPERADO**

`scripts/drill-cp-loss.sh 0` · víctima `ip-10-0-1-77` (i-0735a5deee16b3102),
el nodo que hizo `kubeadm init`.

**Las pruebas solo corren cuando la pérdida está RECONOCIDA por los dos
bucles de control** — Kubernetes marcando el Node `NotReady` *y* el NLB
sacando el target de servicio (`unhealthy`). Sin ese gate, un drill mide el
punto ciego (~40 s de `node-monitor-grace-period`, hasta ~90 s de health
checks) y prueba mucho menos de lo que afirma.

| Prueba | Resultado con el fundador caído y la pérdida reconocida |
|---|---|
| **API escrituras + lecturas** | Objeto nuevo escrito y testigo previo releído · **10/10 sondas consecutivas** al endpoint |
| **Autenticación IAM (end-to-end)** | `platform-admin:jmcastelllanojimenez-yahoo.es`, grupos `["platform-admins","system:authenticated"]` — **puente SSO → rol → webhook → RBAC** con un CP caído. DaemonSet 2/2, como toca |
| **Workloads** | CNPG `3/3 (Cluster in healthy state)` · Kafka 4 pods Running · **0** pods no-Running fuera del nodo parado |
| **Backup de etcd** | `etcd/etcd-20260816T154937Z.db` fresco, tomado desde **`ip-10-0-1-207`** — no desde el parado. **Valida no haber pineado el CronJob.** |

**Tiempos**: parada 109 s · pérdida reconocida +2 s · pruebas bajo 2/3 17 s ·
**curación completa 39 s** · total 167 s. Al arrancar, el nodo reingresó solo
(el guard de reentrada sale con 0 al ver el manifest del API server) y etcd
volvió a **3/3 started** con los tres endpoints sanos (18-22 ms).

### Tres defectos del propio drill, encontrados al ejecutarlo

Los tres se corrigieron y la ejecución de arriba ya es con el script sano:

1. **Un drill fallido dejaba un CP parado.** La primera pasada falló en la
   prueba IAM y salió con el fundador apagado: un ensayo que rompe justo lo
   que venía a demostrar seguro. Ahora un `trap` **rearranca la instancia en
   cualquier salida** desde el instante en que la para (y se desarma al
   verificar la curación, para no ensuciar el final feliz).
2. **La prueba IAM confundía dos identidades.** El drill necesita el perfil
   del lab (parar instancias) pero el `exec` del authenticator hereda ese
   mismo `AWS_PROFILE` — y `platform-admin` **no confía** en una sesión
   `AdministratorAccess` genérica, sino en los puentes SSO (ADR-005
   funcionando). Ahora esa llamada usa su propio `IAM_AWS_PROFILE`
   (`k8s-platform` por defecto).
3. **Sondas informativas mataban el drill.** Escritas con construcciones
   hostiles a `set -euo pipefail` (`[ x -gt 0 ] && ...` como última
   sentencia, tuberías sin `|| true`). Reescritas para **reportar su valor y
   neutralizar su código de salida**: son observaciones, no asertos.

## 4b. Hallazgo lateral: deriva de `my_ip` entre CI y local (ping-pong)

Al aplicar la ceremonia de reemplazo, el plan arrastró **2 cambios** ajenos
al reemplazo: las reglas SSH del SG de control plane y del de workers.

| Origen | `my_ip` |
|---|---|
| Variable de GitHub `TF_VAR_MY_IP` (la que usa el Apply de CI) | `92.172.18.227/32` |
| `tofu/envs/lab/terraform.tfvars` (la que usa cualquier apply local) | `45.85.248.117/32` |

Consecuencia: **cada apply local reescribe la regla SSH y el siguiente apply
de CI la revierte** — ping-pong indefinido sobre una regla de seguridad, sin
que nadie lo note. La ceremonia lo aplicó en silencio porque la inspección
del plan solo vigilaba destrucciones de instancias: otra vez el patrón de
esta pieza — *el silencio parecía "no pasó nada más"*.

Correcciones aplicadas:

**La dirección de la deriva importa, y la conté al revés en el primer
informe**: la variable de GitHub (`92.172.18.227/32`) es **la correcta y
vigente** — coincide con la IP pública real del equipo de operación,
verificada con `curl ifconfig.me`. El `terraform.tfvars` local llevaba un
valor **obsoleto**. Es decir, la ceremonia no "actualizó" nada: **cerró el
SSH desde la IP real del operador**.

Correcciones aplicadas:

1. **La inspección del plan imprime TODOS los cambios** que trae, no solo los
   que rechaza. Sigue abortando por instancias ajenas, pero lo que acepta
   queda a la vista. Esta regla es la misma que arreglamos tres veces en el
   código: *el silencio no es una respuesta segura*.
2. **`terraform.tfvars` alineado con la variable de GitHub** (la fuente de
   verdad) y reglas SSH restauradas a `92.172.18.227/32` en ambos SGs.

## 5. Drill de reemplazo con `kubeadm-certs` invalidado — **SUPERADO**

Escenario: se borró el Secret `kubeadm-certs` (equivale a haber pasado las 2 h
de TTL) y se reemplazó el índice 0 **sin renovar** (`SKIP_RENEW=1`), para que
el join tuviera que fallar antes de que la ceremonia de renovación lo
rescatara.

**La secuencia, con sellos temporales del log del nodo nuevo** (leídos sin
SSH, con pod privilegiado):

```
15:55:08  ✓ Gate open (joined-count=3) — my turn
15:55:10  ✓ certificate-key retrieved     ← la clave OBSOLETA
15:55:10  Join attempt 1/6
15:55:20  Join failed — resetting and retrying in 120s (re-fetching certificate-key)
15:57:21  Join attempt 2/6   → failed
15:59:23  Join attempt 3/6   → failed
16:01:24  Join attempt 4/6   → failed
          ─── 16:01:57  renovación ejecutada desde un superviviente ───
16:03:26  Join attempt 5/6
16:03:50  ✓ kubeadm join (control-plane) completed
```

**Cuatro fallos con la clave caducada, renovación, y el siguiente intento
entra.** La caducidad de 2 h tiene salida operativa demostrada, no teórica.

**Cierre de la ceremonia** (819 s en total):

```
✓ exactly 3 control-plane Nodes, all Ready · exactly 3 etcd members, all started
✓ etcd endpoint health: all endpoints healthy
✓ API target group: registered set == exactly the 3 live control planes,
  ALL healthy (no stale/draining target)
=== Replacement complete in 819s — HA capacity RESTORED ===
```

Los invariantes son **conjuntos exactos**, no conteos: exactamente 3 nodos y
3 miembros (no "al menos"), y el conjunto de targets **registrados** igual al
de instancias vivas — que es lo que descarta un cuarto target agonizando.

Detalles verificados de paso:
- El **plan se inspeccionó antes** de retirar el miembro etcd (el fix del
  cruce 5): `✓ plan inspected and saved` precede a `Removing etcd member`.
- El **attachment del TG se recreó** con la instancia nueva
  (`...api-tg/...,i-0f444dddfabdbfc37,6443`) — la razón de usar `-replace`
  con plan completo en vez de `-target`.
- El **contador monótono** funcionó: el índice 0 rejunto no bajó
  `joined-count` de 3.

## 6. Restore HA con testigo recuperado — **SUPERADO** (193 s)

Ejecutado el 2026-08-16, 17:19-17:22 UTC, **por SSM Run Command**: sin SSH y
sin clave privada. El canal lo construyó esta misma pieza después de que este
drill descubriera que no existía ([INCIDENTS #16](INCIDENTS.md)).

```
17:19:18  === DRILL: HA etcd restore over SSM Run Command ===
17:19:20  Preflight: proving out-of-band access to all three control planes
          ✓ CP-0 / CP-1 / CP-2 — channel proven       ← ANTES de tocar nada
          ✓ witness written before the snapshot (ts=20260816T171927Z)
          ✓ snapshot taken: etcd/etcd-20260816T171944Z.db
          ✓ witness deleted · anti-witness created AFTER the snapshot
          ✓ CP-0, CP-1, CP-2 stopped
17:21:28  the API is now DOWN — this is the scenario, not a failure
          ✓ data dirs preserved as /var/lib/etcd.pre-restore-20260816T171927Z
          ✓ snapshot restored (revision bumped +1000000000, marked compacted)
          ✓ CP-0 serving again — API restored from the single-member etcd
          ✓ CP-1 re-joined — 2/3 · CP-2 re-joined — 3/3
          ✓ THE WITNESS IS BACK (ts=20260816T171927Z)
          ✓ the anti-witness is GONE — etcd genuinely rewound to the snapshot
          ✓ etcd: 3/3 members started and all endpoints healthy
17:22:31  === DRILL PASSED === total 193s
```

**Ventana de API caída: ~35 s** de una ceremonia de 193 s. El grueso es la
parada ordenada y las verificaciones, no la restauración.

**Los dos testigos prueban cosas distintas, y por eso vale como prueba**: el
testigo de vuelta con su sello exacto dice que se recuperó lo que había en el
snapshot; el anti-testigo desaparecido dice que **etcd rebobinó de verdad**.
Sin el segundo, "el testigo está" también describiría un cluster donde no
pasó nada.

Verificación independiente posterior:

| Comprobación | Resultado |
|---|---|
| Nodos | **6/6 Ready** |
| etcd (vista de `etcdctl`) | 3/3 started · `endpoint health` los 3 sanos (17-20 ms) |
| Pods de etcd (vista de la API) | 3/3 `1/1 Running` |
| Targets del API en el NLB | **3/3 healthy** |
| Capa de datos | CNPG `3/3 Cluster in healthy state` · Kafka 4 pods Running |
| Pods fuera de Running en el cluster | **0** |
| ConfigMaps en `default` | solo `kube-root-ca.crt` |
| Lock de la ceremonia | liberado (`ParameterNotFound`) |

### Dos trampas esquivadas al verificar

1. **`Forbidden` no es `NotFound`.** La primera comprobación manual del
   anti-testigo devolvió `Forbidden` (RBAC asentándose tras el rebobinado).
   Darlo por ausencia habría sido [INCIDENTS #17](INCIDENTS.md) cometido al
   minuto de escribirlo. Se reintentó hasta un `NotFound` inequívoco.
2. **La vista de la API va por detrás de los hechos.** El pod de etcd de CP-2
   se leyó `Pending` y luego `0/1` mientras `etcdctl` ya lo daba sano en
   20 ms; alcanzó `1/1` en ~15 s. Anotado en el runbook para que nadie aborte
   una ceremonia sana.

### El bug que encontró el propio lanzamiento

El **primer** intento no ejecutó nada: la lógica de reentrada daba todas las
fases por completadas (`none` encabezaba la lista y activaba el flag en la
primera iteración). Inofensivo entonces —abortó en la verificación con el
cluster intacto, comprobado nodo a nodo— pero **letal en una reanudación
real**: un restore que cree que los data dirs ya están apartados es un
restore que nunca ocurre sobre un cluster que sí está parado. Reescrito como
comparación de índices y **probado con una tabla de verdad**.

## 7. Segundo apply con plan vacío — **CERRADO**

Tras aplicar la retirada de los outputs `ssh_*` (que el cambio de acceso dejó
huérfanos en el state), el plan siguiente es literal:

```
No changes. Your infrastructure matches the configuration.

OpenTofu has compared your real infrastructure against your configuration and
found no differences, so no changes are needed.
```

Idempotencia probada **después** de un ciclo que incluyó destroy completo,
apply desde cero, tres paradas/arranques del drill de pérdida, un reemplazo
de nodo con `-replace` y un restore total de etcd.

## 8. Coste real medido — **DIFERIDO A MAÑANA** (no es criterio de aceptación)

Cost Explorer publica con ~24 h de retraso: el día del apply HA figuraba en
`0.00`. **Medir hoy sería inventar**, así que el dato queda explícitamente
pendiente en lugar de estimado y presentado como medición.

Mientras tanto, el desglose sobre el inventario **real** (en
[CLUSTER.md](CLUSTER.md) §FinOps): 3 CP on-demand + 3 workers spot + NLB +
6 IPv4 + 225 GiB gp3 ≈ **0,2951 $/h ≈ 7,1 $/día**.

Comando para cerrarlo:

```bash
aws ce get-cost-and-usage --time-period Start=2026-08-16 End=2026-08-17 \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE --region us-east-1
```

Dos correcciones que salieron del desglose y ya están aplicadas: la tarifa
spot de la fórmula de Slack estaba **4,5× baja** (0,0055 vs 0,0246 reales) y
las estimaciones previas ignoraban IPv4 y EBS (1,4 $/día).
