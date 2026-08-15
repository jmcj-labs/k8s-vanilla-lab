# CLUSTER.md — Ficha técnica del cluster

Fuente canónica de "qué es este cluster y por qué es así". Se mantiene viva:
cualquier cambio de arquitectura o decisión debe reflejarse aquí en el mismo
PR. Lo que se rompió y lo que aprendimos vive en [INCIDENTS.md](INCIDENTS.md);
este documento no lo duplica, lo referencia.

---

## 1. Identidad

| | |
|---|---|
| Qué es | Cluster Kubernetes vanilla (kubeadm) de laboratorio, base de la app **logistics-lab** |
| Repo | `jmcj-labs/k8s-vanilla-lab` (GitHub) |
| Región / cuenta | `eu-west-1` · cuenta del lab (rol OIDC en la Variable `AWS_ROLE_ARN`) |
| Levantar | Actions → **Apply** → confirm `apply` (o `make apply` + `make platform` + `make smoke-test` en local) |
| Destruir | Actions → **Destroy** → confirm `destroy` (borra también los repos ECR y sus imágenes: `force_delete`) (cron nocturno pausado durante el sprint) |
| Estado | Efímero por diseño: se destruye y recrea sin ceremonia; nada en el cluster es fuente de verdad |

## 2. Arquitectura

**Cómputo**: 1 control plane t3.medium on-demand (+EIP) · 3 workers t3.medium
spot (3, no 2: anti-affinity real para la topología de datos de fase 2 —
CNPG ×3, Kafka ×3) · Ubuntu 24.04 LTS · IMDSv2 obligatorio con hop limit 3 ·
EBS cifrado.

**Red**: VPC dedicada `10.0.0.0/16`, subred pública `10.0.1.0/24` (sin NAT
por coste) · pods `10.244.0.0/16` · services `10.96.0.0/12` · **sin
kube-proxy** — Cilium en strict kube-proxy replacement (routing en modo
tunnel, masquerade iptables).

**Versiones** (las series sin pin se resuelven en cada bootstrap):

| Componente | Versión | Pin |
|---|---|---|
| Kubernetes (kubeadm/kubelet/kubectl) | serie 1.35.x (hoy 1.35.7) | serie |
| containerd (repo Docker) | 2.3.x | latest del repo |
| Cilium (KPR estricto, Gateway API, Hubble) | 1.19.6 | chart |
| Gateway API CRDs (standard) | v1.2.1 | manifiesto |
| EBS CSI driver | chart 2.63.1 | chart |
| cert-manager | chart v1.21.1 | chart |
| CloudNativePG operator | chart 0.29.0 | chart |
| Strimzi operator | chart 1.1.0 | chart |
| kube-prometheus-stack | chart 88.2.0 | chart |
| ecr-credential-provider | v1.36.1 (binario por SHA-256; staging bucket oficial, artifacts.k8s.io roto para >=1.30) | binario |
| aws-iam-authenticator | v0.7.18 (binario con SHA-256; imagen EKS Distro `v0.7.18-cvefix-eks-1-35-12` por digest — upstream no publica imagen) | binario + digest |
| OpenTofu | 1.8.0 | CI |

**Plataforma** (orden real de `platform/install.sh`): namespaces
`infra`/`data`/`logistics` (este último con PSA baseline) + StorageClass
`gp3` default (cifrada, WaitForFirstConsumer) → EBS CSI → cert-manager (+
ClusterIssuer `selfsigned`, gateway-shim activado) → pool LB-IPAM + Gateway
`shared-gw` (HTTPS :443, `*.logistics.lab`, TLS de cert-manager, rutas solo
desde ns `logistics`) → CNPG → Strimzi → kube-prometheus-stack (Grafana
NodePort, Alertmanager off). Solo operators: los clusters PG/Kafka son de la
app.

**Backups** (S2 pieza 1 — "sin restore probado no es backup"): bucket S3
persistente único (`tofu/envs/persistent`, ciclo de vida propio, aplicado a
mano, **nunca** en apply/destroy del cluster) con prefijos `etcd/` (7 días)
y `cnpg/` (lifecycle 18 días — margen sobre los 14 de barman: la política
poda primero, el lifecycle es red de seguridad), versionado + SSE-S3 +
public access bloqueado. Cada encarnación del cluster archiva bajo su
`serverName` propio (`logistics-pg-<gen>`, última generación registrada en
SSM persistente).
CronJob `etcd-backup` cada 6h en `kube-system` (hostNetwork en el CP,
identidad = instance role, write-only a `etcd/*`) · CNPG con
`barmanObjectStore` (WAL continuo + base diario `immediate`, credenciales
del usuario IAM `cnpg-backup` proyectadas desde SSM
`/k8s/persistent/<cluster>/…`, prefijo que sobrevive al destroy). Drills de
restore: [RUNBOOK-restore-etcd.md](RUNBOOK-restore-etcd.md) y
[RUNBOOK-restore-cnpg.md](RUNBOOK-restore-cnpg.md).

## 3. Decisiones no-default y por qué

| Decisión | Por qué (una línea) | Detalle |
|---|---|---|
| OpenTofu, no Terraform | Licencia y gobernanza comunitaria | [ADR-001](decisions/ADR-001-opentofu-vs-terraform.md) |
| Workers spot + CP on-demand | 60% de ahorro asumiendo reclaims; el CP nunca se pierde | [ADR-002](decisions/ADR-002-spot-workers-ondemand-cp.md) |
| `skipPhases: addon/kube-proxy` + Cilium KPR=true | kube-proxy nunca existe; eBPF hace su trabajo — requiere `k8sServiceHost/Port` cableados para evitar el deadlock de bootstrap | [ADR-003](decisions/ADR-003-cilium-ebpf.md) |
| Kubeconfig y join data en SSM | CI opera el cluster sin abrir SSH al runner | [ADR-004](decisions/ADR-004-kubeconfig-ssm.md) |
| IMDS hop limit **3** (no 1, no 2) | El tunnel de Cilium añade un salto al camino de vuelta pod←IMDS; con 2 el EBS CSI muere sin credenciales | [INCIDENTS #4](INCIDENTS.md) |
| `--provider-id` en el kubelet (los 4 nodos, pre-init/join) | kubeadm vanilla deja `providerID` vacío y el EBS CSI lo exige; un solo mecanismo, sin RBAC ni patches | [INCIDENTS #3](INCIDENTS.md) |
| `controller.region` explícito en el EBS CSI | Defensa en profundidad: no depender de IMDS para descubrir la región | [INCIDENTS #4](INCIDENTS.md) |
| Gateway API CRDs **antes** del helm install de Cilium | El operator solo habilita su controller de Gateway API si las CRDs ya existen | `bootstrap/control-plane.yaml` |
| Pool LB-IPAM (`172.20.255.0/24`, solo ns `infra`) | Sin cloud-controller nadie asigna IP al Service del Gateway y `Programmed` nunca llega; la IP es virtual, no anunciada | [INCIDENTS #7](INCIDENTS.md) |
| API server 6443 abierto a `0.0.0.0/0` | Los runners de CI (IPs dinámicas) ejecutan platform+smoke vía kubeconfig; TLS + certificados como control de acceso, SSH sigue cerrado a `my_ip` | [ADR-004](decisions/ADR-004-kubeconfig-ssm.md), README |
| `user_data_base64` (nunca `user_data`) | cloud-init va gzip+base64; el contrato del provider lo exige y su violación rompe updates in-place | [INCIDENTS #5](INCIDENTS.md) |
| SG del CP sin reglas inline (todo standalone) | Mezclar inline + standalone borra reglas ajenas en cada apply | [INCIDENTS #6](INCIDENTS.md) |
| Acceso diario vía IAM (aws-iam-authenticator, backend DynamicFile) | Credenciales STS efímeras por identidad, revocación = membresía de grupo en Identity Center; el kubeconfig admin queda solo como break-glass | [ADR-005](decisions/ADR-005-iam-access.md) |
| Registro ECR privado, tags inmutables por SHA, roles CI separados infra/app | Sin pull-secrets (instance role + credential provider), rollbacks reproducibles, separación de deberes | [ADR-006](decisions/ADR-006-ecr-registry.md) |
| Perfiles de acceso, no personas (`platform/access/profiles.yaml`) | Alta/baja de humanos sin tocar el repo: mappings y RBAC se renderizan del mismo fichero | [ADR-005](decisions/ADR-005-iam-access.md) |
| KafkaTopics como recurso de plataforma (`auto.create.topics.enable=false`) | Un topic mal escrito falla, no crea silenciosamente uno RF1; plataforma dueña del recurso, Repo 2 del contrato de eventos | brief 3b |
| Sin `jobs` en el RBAC de developer | Migraciones por auto-migrate (DDL idempotente + advisory lock), no Jobs | brief 3b |
| SA `default` con `automountServiceAccountToken: false` | Contrato con Repo 2: los charts no montan token de SA | brief 3b |
| PodMonitor genérico de app en plataforma | Selecciona por `app.kubernetes.io/part-of: logistics-lab`; Repo 2 solo pone el label y el puerto `metrics` | brief 3b |
| **Contrato de pods de Repo 2** (lo exige `make smoke-app-contract`) | Cada Deployment lleva `app.kubernetes.io/name=<servicio>`; el container principal se llama **exactamente** `<servicio>`; cada servicio expone en el puerto `metrics` la métrica `logistics_service_info{service="<servicio>"} 1` | brief 3b |
| Proyección de secrets a `logistics` (no acceso a `data`) | El developer no lee Secrets en `data`; se proyecta el mínimo (PG app + Kafka `ca.crt`) sin metadata del origen | brief 3b |
| Bucket de backups único y **persistente** (stack propio, manual) | Los backups deben sobrevivir a cualquier destroy del cluster; consumo por variable, no remote state — grafos desacoplados | brief S2-1, `tofu/envs/persistent` |
| etcd backup con **instance role** vs barman con **usuario IAM** | El CronJob es hostNetwork en el CP (IMDS le funciona sin tocar la CCNP); los pods CNPG están tras el deny de IMDS que NO se agujerea — credencial estática mínima, acotada a `cnpg/*` | brief S2-1 |
| Snapshots etcd write-only desde el CP (`s3:PutObject` a `etcd/*`, nada más) | Un CP comprometido no puede leer ni borrar los backups existentes | brief S2-1 |

## 4. Operación

**Smoke de contrato de app** (`make smoke-app-contract`, con `GITHUB_SHA`):
se ejecuta tras el deploy de Repo 2 (la coronación, no el Apply): los 4
servicios Ready con imagen `<repo>:<SHA>` **traída de ECR por digest** (pull
real, no existencia) y targets de Prometheus `up==1` con muestras.

**Handoff tras recreate**: cada apply desde cero cambia `K8S_SERVER` y
`K8S_CA_DATA` (el resto — `K8S_CLUSTER_ID`, `AWS_ROLE_ARN`, `AWS_REGION`,
`K8S_DEVELOPER_ROLE_ARN` — es estable). Procedimiento: destroy → apply
(smoke 38+ verde) → el operador actualiza esas 2 variables en el repo
logistics-lab → `workflow_dispatch` (rebuild→push SHA→deploy→e2e) →
`make smoke-app-contract`. El refresh es manual (deuda §5).

**Smoke test** (`make smoke-test`, también al final del workflow Apply):
4/4 nodos Ready · cero pods kube-proxy · `cilium-dbg` reporta
KubeProxyReplacement True · providerID en los 4 nodos · PVC gp3 dinámico
Bound **y montado** (pod Ready) con limpieza · Gateway `Accepted` y
`Programmed` · operators CNPG y Strimzi Ready.

**Acceso** (ADR-005 — dos `sso-session` separadas, ver README):
- Diario: `make kubeconfig-admin` (rol `platform-admin` → cluster-admin) o
  `make kubeconfig-dev` (rol `developer` → ns `logistics`). Kubeconfigs sin
  credenciales estáticas: bloque `exec` → `aws-iam-authenticator token` con
  `--forward-session-name`; la sesión viene de `aws sso login`.
- Break-glass: `make kubeconfig` → cert admin de kubeadm desde SSM (ADR-004).
  Solo si el authenticator no responde.
- `make ssh-cp` / `make ssh-worker`
- Grafana: `kubectl -n infra get svc kube-prometheus-stack-grafana` →
  `http://<ip-worker>:<nodeport>` (password en el secret
  `kube-prometheus-stack-grafana`)

**Qué login necesita cada target de make** — la trampa: `aws sso login`
renueva el token del perfil, pero los targets que llaman a `aws` a pelo no
llevan `--profile`, así que usan lo que haya en el ambiente (`AWS_PROFILE`
o el perfil `default`):

| Target | Credencial que usa |
|--------|--------------------|
| `make apply` / `plan` / `destroy` | el provider lee `aws_profile` de `terraform.tfvars` → basta `aws sso login --profile k8s-vanilla-lab`, sin exportar nada |
| `make kubeconfig` / `platform` / `smoke-test` / `smoke-app-contract` | CLI ambiente → **exportar `AWS_PROFILE=k8s-vanilla-lab`** (`.envrc` + direnv, o prefijo en el comando) además del login |
| `make kubeconfig-admin` / `kubeconfig-dev` | sesiones SSO `k8s-platform` / `k8s-dev` (ADR-005) — perfiles distintos del de tofu |

Síntoma típico de mezclarlos: `Token has expired` en `make kubeconfig` con
los SSO recién logueados — ver `docs/troubleshooting.md`.

**FinOps**: ~$0.055/h (CP $0.038 + 3×spot $0.0055) ≈ **$1.3/día** si se deja
encendido. El cron de destroy nocturno está **pausado** durante el sprint —
el cluster no se apaga solo: destruir a mano al terminar el día. Slack
notifica cada apply (coste/hora) y cada destroy (uptime y coste estimado).

## 5. Límites conocidos (deuda consciente)

Cada uno con su "cuándo se paga" en [PLAN-SPRINTS.md](PLAN-SPRINTS.md):

- ~~IMDS alcanzable desde toda la red de pods~~ **CERRADA (2026-08-11)**:
  CiliumClusterwideNetworkPolicy deniega `169.254.169.254` a todos los pods
  excepto el EBS CSI (`platform/policies/`), verificada en el smoke con
  drops de Hubble — incluida la comprobación anti-falso-negativo de la
  excepción (caché STS ~1h).
- **Exposición del Gateway por NodePort** (IP LB virtual, no anunciada) —
  hasta el NLB de Sprint 2.
- ~~Ingreso sin e2e probado~~ **CERRADA (2026-08-15)**: e2e exterior en la
  coronación de S1 — `POST /shipments` HTTP 201 por el Gateway con TLS/SNI
  desde fuera del cluster, y gRPC (`CalculateRoute`) por la GRPCRoute;
  evidencia en [HANDOFF.md](HANDOFF.md). La *exposición* sigue por NodePort
  hasta el NLB de S2.
- **API 6443 pública** y **kubeconfig admin en SSM** (ya solo break-glass,
  ADR-005) — aceptable en lab efímero, inaceptable en cualquier otro contexto.
- **Egress a la VIP del Gateway no es restringible por CNP del cliente**: el
  tráfico a la LB del Gateway se redirige a Envoy (`to-proxy`) antes de la
  egress policy, así que una CNP de egress ni la puerta ni hace falta
  (INCIDENTS #10). `allowedRoutes` limita **la propiedad de rutas** (qué ns
  puede adjuntar HTTPRoutes — aquí `logistics`), no **la autorización de
  peticiones** (qué pods pueden enviar tráfico por el Gateway); no sustituye
  al control de egress. Riesgo aceptado en el MVP: no hay requisito de aislar
  entre sí a los clientes *dentro* de `logistics`. Control futuro: L7/auth en
  el Gateway + policies por servicio, Fase 1.5.
- **Rotación manual de las access keys de barman** (usuario `cnpg-backup`)
  hasta External Secrets (S3): crear segunda key → sobrescribir el parámetro
  SSM persistente → `make platform` (el Secret lleva `cnpg.io/reload:
  "true"`, CNPG lo recarga sin rollout) → verificar WAL → borrar la vieja
  (flujo completo en `tofu/envs/persistent/README.md`). La migración del
  in-tree `barmanObjectStore` (deprecado por CNPG) al plugin Barman Cloud
  va al mismo sprint.
- **Rotación de credenciales proyectadas = re-ejecutar la proyección**
  (`make platform`), hasta External Secrets (S3). Nada en Git.
- **Refresh manual de variables tras recreate**: `K8S_SERVER`/`K8S_CA_DATA`
  se actualizan a mano en logistics-lab; un canal de publicación de metadatos
  no sensibles es candidato post-S1. La cara destroy de esta deuda es la
  ventana de variable stale (PR #4 de logistics-lab): al destruir, borrar
  `K8S_SERVER` allí para que su deploy quede en skip y no en rojo — paso en
  el runbook de destroy (`docs/troubleshooting.md`).
- **`tofu destroy` no elimina los volúmenes EBS dinámicos del CSI** (PVCs de
  PG/Kafka): los provisiona el driver en runtime, Tofu no los rastrea, así que
  quedan **huérfanos (`available`) facturando** tras el destroy. Verificación
  y borrado manual en el runbook de destroy (`docs/troubleshooting.md`).
  Automatizar el cleanup por tag `kubernetes.io/created-for/pvc/*` (como ya se
  hace con las ENIs huérfanas) es candidato S2. Con los backups de S2-1
  (base+WAL en S3, restore con drill) esos volúmenes **ya no son la vía de
  conservación**: borrarlos tras un destroy no pierde nada.
- **Anti-affinity `required` con 3 workers**: la caída de un worker deja la
  tercera instancia (PG o Kafka) Pending hasta que el nodo vuelve — esperado
  y aceptado; no se suaviza a `preferred` (perdería la garantía de
  distribución que la topología de datos necesita).
- **Memoria justa en los workers** (t3.medium, 4 GiB): PG + Kafka + monitoring
  caben por requests, pero los limits sobrecomprometen — riesgo OOM bajo
  carga sostenida, aceptable en lab.
- **Ventana sin tokens IAM en cada bootstrap**: entre el arranque del API
  server y el rollout del DaemonSet del authenticator solo funciona el
  break-glass. Asumido (ADR-005) — el authenticator nunca es SPOF de acceso.
- **Sin HA, sin backups** — Sprint 2 (backups con restore probado primero).
- **Subred pública sin NAT** y **workers spot** — tradeoffs de coste
  documentados que sobreviven a ambos sprints.
- **Token de join con TTL 24h** — workers que se unan más tarde necesitan
  token nuevo (`docs/troubleshooting.md`).

## 6. Historial de incidencias

Ver [INCIDENTS.md](INCIDENTS.md) — 7 incidencias con causa raíz y fix (4 del
montaje manual, 3 de la automatización).
