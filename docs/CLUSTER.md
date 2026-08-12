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

## 3. Decisiones no-default y por qué

| Decisión | Por qué (una línea) | Detalle |
|---|---|---|
| OpenTofu, no Terraform | Licencia y gobernanza comunitaria | [ADR-001](decisions/ADR-001-opentofu-vs-terraform.md) |
| Workers spot + CP on-demand | 60% de ahorro asumiendo reclaims; el CP nunca se pierde | [ADR-002](decisions/ADR-002-spot-workers-ondemand-cp.md) |
| `skipPhases: addon/kube-proxy` + Cilium KPR=true | kube-proxy nunca existe; eBPF hace su trabajo — requiere `k8sServiceHost/Port` cableados para evitar el deadlock de bootstrap | [ADR-003](decisions/ADR-003-cilium-ebpf.md) |
| Kubeconfig y join data en SSM | CI opera el cluster sin abrir SSH al runner | [ADR-004](decisions/ADR-004-kubeconfig-ssm.md) |
| IMDS hop limit **3** (no 1, no 2) | El tunnel de Cilium añade un salto al camino de vuelta pod←IMDS; con 2 el EBS CSI muere sin credenciales | [INCIDENTS #4](INCIDENTS.md) |
| `--provider-id` en el kubelet (los 3 nodos, pre-init/join) | kubeadm vanilla deja `providerID` vacío y el EBS CSI lo exige; un solo mecanismo, sin RBAC ni patches | [INCIDENTS #3](INCIDENTS.md) |
| `controller.region` explícito en el EBS CSI | Defensa en profundidad: no depender de IMDS para descubrir la región | [INCIDENTS #4](INCIDENTS.md) |
| Gateway API CRDs **antes** del helm install de Cilium | El operator solo habilita su controller de Gateway API si las CRDs ya existen | `bootstrap/control-plane.yaml` |
| Pool LB-IPAM (`172.20.255.0/24`, solo ns `infra`) | Sin cloud-controller nadie asigna IP al Service del Gateway y `Programmed` nunca llega; la IP es virtual, no anunciada | [INCIDENTS #7](INCIDENTS.md) |
| API server 6443 abierto a `0.0.0.0/0` | Los runners de CI (IPs dinámicas) ejecutan platform+smoke vía kubeconfig; TLS + certificados como control de acceso, SSH sigue cerrado a `my_ip` | [ADR-004](decisions/ADR-004-kubeconfig-ssm.md), README |
| `user_data_base64` (nunca `user_data`) | cloud-init va gzip+base64; el contrato del provider lo exige y su violación rompe updates in-place | [INCIDENTS #5](INCIDENTS.md) |
| SG del CP sin reglas inline (todo standalone) | Mezclar inline + standalone borra reglas ajenas en cada apply | [INCIDENTS #6](INCIDENTS.md) |
| Acceso diario vía IAM (aws-iam-authenticator, backend DynamicFile) | Credenciales STS efímeras por identidad, revocación = membresía de grupo en Identity Center; el kubeconfig admin queda solo como break-glass | [ADR-005](decisions/ADR-005-iam-access.md) |
| Registro ECR privado, tags inmutables por SHA, roles CI separados infra/app | Sin pull-secrets (instance role + credential provider), rollbacks reproducibles, separación de deberes | [ADR-006](decisions/ADR-006-ecr-registry.md) |
| Perfiles de acceso, no personas (`platform/access/profiles.yaml`) | Alta/baja de humanos sin tocar el repo: mappings y RBAC se renderizan del mismo fichero | [ADR-005](decisions/ADR-005-iam-access.md) |

## 4. Operación

**Smoke test** (`make smoke-test`, también al final del workflow Apply):
3/3 nodos Ready · cero pods kube-proxy · `cilium-dbg` reporta
KubeProxyReplacement True · providerID en los 3 nodos · PVC gp3 dinámico
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
- **Ingreso sin e2e probado**: `Programmed=True` demuestra reconciliación,
  no tráfico; el HTTPRoute + petición HTTPS real llega con la app.
- **API 6443 pública** y **kubeconfig admin en SSM** (ya solo break-glass,
  ADR-005) — aceptable en lab efímero, inaceptable en cualquier otro contexto.
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
