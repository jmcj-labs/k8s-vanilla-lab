# Evidencia de coronación — S2 pieza 3 (HA del control plane)

**Fecha**: 2026-08-16 · **ADR**: [ADR-007](decisions/ADR-007-api-endpoint-nlb.md) ·
**PR**: #65 (5 cruces de Codex) · **SHA revisado**: `7956236` · **Merge**: `032d865`

Criterio de coronación del brief #S2-3, con la evidencia de cada punto.
Los apartados marcados **PENDIENTE** se rellenan al ejecutarlos.

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

`scripts/drill-cp-loss.sh 0` · víctima: `ip-10-0-1-77` (i-0735a5deee16b3102),
el nodo que hizo `kubeadm init`. Parado 15:25:02Z → 15:27:02Z (122 s hasta
`stopped`), cluster operando a **2/3** durante toda la ventana.

| Prueba | Resultado con el fundador caído |
|---|---|
| **API escrituras + lecturas** | Escribió un objeto nuevo y releyó el testigo previo al corte · **10/10 sondas consecutivas** al endpoint (una sola podría ser suerte con fail-open) |
| **Autenticación IAM** | El webhook **respondió** `Unauthorized` a una identidad no mapeada — un "no" **autenticado**, no un timeout: la cadena API server → authenticator local vive en los supervivientes (ver matiz abajo) |
| **Workloads** | CNPG `3/3 · Cluster in healthy state` · Kafka 3 brokers Running |
| **Backup de etcd** | `etcd/etcd-20260816T152823Z.db` fresco en S3, tomado desde **`ip-10-0-1-207`** — NO desde el nodo parado. **La decisión de no pinear el CronJob queda validada en el único momento en que importa.** |

**Curación**: al arrancar la instancia, el nodo reingresó solo (cloud-init no
se re-ejecuta; el guard de reentrada del join sale con 0 al ver el manifest
del API server) → **etcd 3/3 started** y `endpoint health --cluster` con los
tres sanos (18-22 ms).

### Matiz honesto sobre la prueba IAM

La prueba **end-to-end** (asumir `platform-admin` y ver el username mapeado)
no se pudo ejecutar desde esta máquina: el rol confía en los puentes SSO
`k8s-platform`/`k8s-dev` y en el rol de CI — **no** en una sesión
`AdministratorAccess` genérica —, exactamente como ADR-005 quiso. Es una
limitación de credenciales del operador, no del cluster; la prueba del
**camino del webhook** sí es concluyente. Para el sello completo basta
`aws sso login --profile k8s-platform` antes del drill.

### Dos defectos del propio drill, encontrados al ejecutarlo

1. **Un drill fallido dejaba un CP parado.** Al fallar la prueba IAM, el
   script salió con el fundador aún apagado: un ensayo que rompe justo lo que
   venía a demostrar seguro. Corregido con un `trap` que **rearranca la
   instancia en cualquier salida** desde el momento en que la para.
2. **La prueba IAM era todo-o-nada.** Ahora degrada explícitamente: si no hay
   sesión capaz de asumir el rol, prueba el camino del webhook y **dice** que
   eso es lo que está probando, en vez de fallar o —peor— callar.

## 5. Drill de reemplazo con `kubeadm-certs` invalidado

PENDIENTE — dos terminales; renovación dentro de la ventana de 6 reintentos.

## 6. Restore HA con testigo recuperado

**BLOQUEADO POR ACCESO FUERA DE BANDA — no por el diseño.**

El restore HA para los TRES control planes; con las tres APIs abajo,
`kubectl` deja de existir como herramienta por definición, así que la
ceremonia se orquesta por SSH (así está escrita en
`scripts/drill-restore-etcd-ha.sh`). En la máquina desde la que opero:

- No está la clave privada del par `k8s-vanilla-lab` (`~/.ssh` solo tiene
  `agent` y `known_hosts`).
- **Session Manager no es alternativa**: `describe-instance-information`
  devuelve 0 instancias gestionadas y el role de nodo no lleva
  `AmazonSSMManagedInstanceCore`.

Los otros drills **no** dependen de SSH (usan kubectl + API de AWS) y sí se
ejecutan. Opciones para desbloquear este, en orden de preferencia técnica:

1. **Clave SSH disponible** en `~/.ssh/k8s-vanilla-lab.pem` → el drill corre
   tal cual está escrito.
2. **Adoptar Session Manager** (`AmazonSSMManagedInstanceCore` en los roles
   de nodo) y portar la ceremonia a `aws ssm send-command`. Mejora de fondo:
   permitiría **cerrar el puerto 22** al mundo y dejar el acceso fuera de
   banda auditado en CloudTrail — pero es un cambio de alcance con su propio
   PR y su propio cruce, no algo que colar en la coronación.
3. Diferir el drill declarándolo deuda con fecha (la regla de la casa dice
   que entonces el runbook es esperanza, no backup: **no** recomendado).

## 7. Segundo apply con plan vacío

PENDIENTE

## 8. Coste real medido

PENDIENTE — Cost Explorer → `CLUSTER.md` §FinOps.
