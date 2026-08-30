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

**Cómputo**: **3 control planes t3.medium on-demand con etcd stacked (S2-3,
ADR-007** — HA de nodo: sobrevive a perder un CP; **una sola AZ**, no es HA
zonal) · 3 workers t3.medium spot (3, no 2: anti-affinity real para la
topología de datos de fase 2 — CNPG ×3, Kafka ×3) · Ubuntu 24.04 LTS ·
IMDSv2 obligatorio con hop limit 3 · EBS cifrado. El EIP del CP **ya no
existe**: IPs públicas auto-asignadas solo para egress; ningún consumidor
ancla a IPs de nodo.

**Red**: VPC dedicada `10.0.0.0/16`, subred pública `10.0.1.0/24` (sin NAT
por coste) · pods `10.244.0.0/16` · services `10.96.0.0/12` · **sin
kube-proxy** — Cilium en strict kube-proxy replacement (routing en modo
tunnel, masquerade iptables). **Entrada de aplicación: NLB internet-facing
(S2-2)** — TCP/443 en passthrough hacia el NodePort determinista **30443**
del Gateway (fuente de verdad en Tofu, `gateway_nodeport`); el SG de
workers solo acepta ese puerto desde el SG del NLB. **El MISMO NLB es el
endpoint del API (S2-3, ADR-007)**: listener TCP/6443 → TG propio hacia los
3 CPs (`preserve_client_ip=false` — los CPs son clientes del endpoint que
los tiene como targets, hairpin), `controlPlaneEndpoint` de kubeadm = DNS
del NLB, y el SG de CPs solo acepta 6443 desde el SG del NLB (murió
`0.0.0.0/0:6443`). Acoplamiento app/API en un recurso: **declarado y
aceptado en lab**. No hay SSH entrante (acceso por SSM, INCIDENTS #16). DNS del NLB nuevo en
cada apply (output `nlb_dns_name`) — **el refresh de `K8S_SERVER` sigue
vivo** —, sin Route53 hasta post-S4.

**Versiones** (las series sin pin se resuelven en cada bootstrap):

| Componente | Versión | Pin |
|---|---|---|
| Kubernetes (kubeadm/kubelet/kubectl) | serie `stable:/v1.35`, sin patch fijado | serie |
| containerd (repo Docker) | 2.3.x | latest del repo |
| Cilium (KPR estricto, Gateway API, Hubble) | 1.20.1 | chart |
| Gateway API CRDs (6 standard + overlay experimental TLSRoute) | v1.6.1 | manifiestos individuales |
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
type NodePort pero inaccesible desde fuera — acceso por port-forward,
Alertmanager off). Solo operators: los clusters PG/Kafka son de la
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
| `--provider-id` en el kubelet (los 6 nodos, pre-init/join) | kubeadm vanilla deja `providerID` vacío y el EBS CSI lo exige; un solo mecanismo, sin RBAC ni patches | [INCIDENTS #3](INCIDENTS.md) |
| `controller.region` explícito en el EBS CSI | Defensa en profundidad: no depender de IMDS para descubrir la región | [INCIDENTS #4](INCIDENTS.md) |
| Gateway API CRDs **antes** del helm install de Cilium | El operator solo habilita su controller de Gateway API si las CRDs ya existen | `bootstrap/control-plane.yaml` |
| Bootstrap directo al stack de red final | Un cluster nuevo nace en Cilium 1.20.1 + Gateway API v1.6.1; 4a/4b quedan como operaciones en vivo | [ADR-009](decisions/ADR-009-direct-network-bootstrap.md) |
| Pool LB-IPAM (`172.20.255.0/24`, solo ns `infra`) | Sin cloud-controller nadie asigna IP al Service del Gateway y `Programmed` nunca llega; la IP es virtual, no anunciada | [INCIDENTS #7](INCIDENTS.md) |
| API server público **por el NLB** (los CPs solo aceptan 6443 del SG del NLB) | Los runners de CI (IPs dinámicas) ejecutan platform+smoke vía kubeconfig; TLS + certificados/IAM como control de acceso. El acceso directo a las IPs de CP murió en S2-3, y el SSH entrante en el cierre de la pieza | [ADR-004](decisions/ADR-004-kubeconfig-ssm.md) + [ADR-007](decisions/ADR-007-api-endpoint-nlb.md) |
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
| **NLB en L4 puro (TLS passthrough)** | Terminar en el NLB no rompería gRPC (ALPN existe) — rompería el diseño TLS/SNI del Gateway con cert-manager; TCP/443 → TCP conserva la terminación donde está | brief S2-2 |
| **Targets `instance` sobre NodePort determinista 30443** | IP targets descartados por diseño: VIP LB-IPAM no anunciada, pods inalcanzables en tunnel mode, acoplamiento a direcciones | brief S2-2 |
| **Sin Proxy Protocol v2** | En Cilium es global por Gateway: rompería el acceso in-cluster directo a la VIP y los health checks; la IP de cliente se preserva nativa (instance+TCP) y viaja en X-Forwarded-For | brief S2-2 |
| **Health check TCP (no HTTPS) + fail-open asumido** | HTTPS sin SNI daría falsos negativos; TCP prueba datapath, el e2e prueba semántica. El NLB hace fail-open con todo unhealthy → **la seguridad descansa en los SG, nunca en el health state** | brief S2-2 |
| **Cross-zone OFF explícito** | Una sola AZ hoy: el NLB no añade resiliencia zonal y fingirlo en config sería mentir. La pieza 3 entregó HA **de nodo** (3 CPs, misma AZ); la zonal queda como deuda consciente post-S2 | brief S2-2 corregido por S2-3 |
| **API por el NLB, listener TCP/6443 y TG propio (`preserve_client_ip=false`)** | Endpoint estable que sobrevive a cualquier CP; hairpin CP→NLB→CP exige no preservar IP (AWS lo desaconseja con targets-clientes); el TG de aplicación conserva `true` — ambos explícitos | [ADR-007](decisions/ADR-007-api-endpoint-nlb.md) |
| **CP SG: 6443 solo desde el SG del NLB** | La API sigue pública por diseño (ADR-004) pero por la puerta única; prueba negativa sobre las 3 IPs públicas de CP en smoke §14 | ADR-007 |
| **Join de CPs secuenciado por gate SSM (`cp/joined-count`)** | La guía HA de kubeadm exige joins de CP de uno en uno; el gate serializa sin lock server. Contador **monótono**: el reemplazo de un índice bajo no baja la barrera que ya pasaron los altos | ADR-007 |
| **El fundador se decide en runtime, no en el plan** | Un índice 0 reconstruido encontraría `cp/joined-count` en SSM y **se une** en vez de inicializar un segundo cluster sobre el vivo (hallazgo Codex, cruce 3) | ADR-007, [runbook de reemplazo](RUNBOOK-replace-control-plane.md) |
| **Guard de recreate que falla CERRADO** | Un state ilegible (credenciales, backend, lock) no puede probarse libre del CP singleton: abortar es la única respuesta segura | `scripts/guard-legacy-cp-state.sh` |
| **Path SSM `cp/` excluido del role de worker** | El certificate-key eleva a control plane a quien lo tenga; el worker enumera ARNs exactos y no lo ve (hallazgo Codex S2-3). No es "exclusivo de CP": el role OIDC de CI lee `/k8s/*` y ya custodia el kubeconfig admin | ADR-007 |
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
(smoke 64 checks OK en CI) → el operador actualiza esas 2 variables en el repo
logistics-lab → `workflow_dispatch` (rebuild→push SHA→deploy→e2e) →
`make smoke-app-contract`. El refresh es manual (deuda §5).

**Smoke test** (`make smoke-test`, también al final del workflow Apply):
6/6 nodos Ready (3 CPs + 3 workers, `EXPECTED_NODES`) · cero pods
kube-proxy · `cilium-dbg` reporta KubeProxyReplacement True · providerID en
los 6 nodos · PVC gp3 dinámico
Bound **y montado** (pod Ready) con limpieza · Gateway `Accepted` y
`Programmed` · operators CNPG y Strimzi Ready.

**Acceso** (ADR-005 — dos `sso-session` separadas, ver README):
- Diario: `make kubeconfig-admin` (rol `platform-admin` → cluster-admin) o
  `make kubeconfig-dev` (rol `developer` → ns `logistics`). Kubeconfigs sin
  credenciales estáticas: bloque `exec` → `aws-iam-authenticator token` con
  `--forward-session-name`; la sesión viene de `aws sso login`.
- Break-glass: `make kubeconfig` → cert admin de kubeadm desde SSM (ADR-004).
  Solo si el authenticator no responde.
- `make ssm-cp` / `make ssm-worker` (SSM; no existe SSH entrante)
- Grafana — **por port-forward** (S2-2 cerró los NodePort al exterior; no
  abrir otro puerto ni regla):
  `kubectl port-forward -n infra svc/kube-prometheus-stack-grafana 3000:80`
  → `http://localhost:3000` (password en el secret
  `kube-prometheus-stack-grafana`)

**Qué login necesita cada target de make** — el Makefile defaultea
`AWS_PROFILE=k8s-vanilla-lab` en local (override respetado; en CI no
aplica) y todo target de CLI pasa por el preflight `check-aws`, que falla
nombrando el perfil y el login exacto:

| Target | Credencial que usa |
|--------|--------------------|
| `make apply` / `plan` / `destroy` | el provider lee `aws_profile` de `terraform.tfvars` → basta `aws sso login --profile k8s-vanilla-lab` |
| `make kubeconfig` / `platform` / `smoke-test` / `smoke-app-contract` | `AWS_PROFILE` del entorno, con default local `k8s-vanilla-lab` → el mismo login basta, sin exportar nada |
| `make kubeconfig-admin` / `kubeconfig-dev` | sesiones SSO `k8s-platform` / `k8s-dev` (ADR-005) — perfiles distintos del de tofu |

Historia del cepo (`Token has expired` sin dueño): `docs/troubleshooting.md`.

**Acceso a los nodos (desde INCIDENTS #16): SSM, cero SSH entrante.**

| Necesidad | Herramienta | Identidad en el nodo |
|---|---|---|
| Shell humana | `make ssm-cp CP_INDEX=n` · `make ssm-worker WORKER_INDEX=n` (Session Manager) | `ssm-user` (sudo sin contraseña) |
| Ceremonias guionizadas | `scripts/lib/ssm-exec.sh` → `send-command` con `AWS-RunShellScript` | **root** directamente |

Requiere el plugin local: `brew install --cask session-manager-plugin` (o el
bundle sin sudo de `s3.amazonaws.com/session-manager-downloads/plugin/latest/`).

No hay regla de entrada TCP/22 en ningún SG y no existe clave privada que
custodiar: el acceso viaja con el instance profile. `key_name` sigue en las
instancias **a propósito** — es `ForceNew` y quitarlo recrearía los 6 nodos
sin ganancia; queda vestigial hasta el próximo nacimiento desde cero.

**FinOps** (desglose del 2026-08-16 sobre el inventario REAL de la pieza 3):

| Concepto | $/h | $/día |
|---|---|---|
| 3 × t3.medium on-demand (control planes) | 0,1368 | 3,28 |
| 3 × t3.medium spot (workers, precio real del día) | 0,0738 | 1,77 |
| NLB (tarifa base; NLCU aparte, despreciable a este tráfico) | 0,0252 | 0,60 |
| 6 × IPv4 pública | 0,0300 | 0,72 |
| 225 GiB gp3 (6×30 raíz + PVCs 3×10 + 3×5) | 0,0293 | 0,70 |
| **TOTAL** | **0,2951** | **≈ 7,1** |

### Medición real (2026-08-17, sobre el día 16)

| Día | Forma del cluster | Gasto MEDIDO |
|---|---|---|
| 2026-08-15 | pieza 2 (1 CP), parte del día | **1,55 USD** |
| 2026-08-16 | pieza 2 por la mañana + **HA ~3 h** | **1,97 USD** |

Desglose del 16: EC2 compute 1,305 · VPC 0,237 · **ELB 0,204** · EC2-Other
0,201 · S3 0,003 · SSM 0,001 (+0,020 del propio Cost Explorer, que cobra por
consulta).

**La medición NO valida ni desmiente la tabla de arriba: mide otra cosa.**
Esos 7,1 $/día son la proyección de un día **entero** encendido; el cluster
HA vivió unas 3 horas antes del destroy. Para validar la proyección haría
falta o bien dejarlo 24 h encendido —contrario a la disciplina que nos
impusimos— o bien granularidad horaria en Cost Explorer, que es **opt-in de
la cuenta pagadora y aquí está deshabilitada** (`AccessDeniedException:
Hourly data granularity is an opt-in only feature`).

**Lo que sí se puede afirmar, y es lo que importa para FinOps**: operado como
lo operamos —encender, trabajar, destruir— el laboratorio cuesta **~2 USD por
día de trabajo**, no 7. La factura la manda el número de horas, no la tarifa
diaria teórica.

Para repetir la medición:

```bash
# OJO: Start y End van en el MISMO argumento, separados por coma —
# con un espacio el CLI responde "Unknown options: End=..."
aws ce get-cost-and-usage --time-period Start=<AAAA-MM-DD>,End=<+1d> \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE --region us-east-1
```

Dos correcciones que salieron de hacer este desglose:

- La fórmula del aviso de Slack usaba **0,0055 $/h** de spot para t3.medium
  cuando el precio real ronda **0,0246** — un factor 4,5 que hacía optimista
  cada informe. Corregido.
- Las estimaciones anteriores (~2,1 $/día en la pieza 2, ~5 en el primer
  borrador de esta) **ignoraban IPv4 y EBS**, que suman 1,4 $/día. El coste
  de la pieza 2 estaba igualmente subestimado por la misma razón.

El cron de destroy nocturno sigue **pausado** durante el sprint — el cluster
no se apaga solo: destruir a mano al terminar el día. Apagado sigue costando
cero salvo el bucket de backups (céntimos).

## 5. Límites conocidos (deuda consciente)

Cada uno con su "cuándo se paga" en [PLAN-SPRINTS.md](PLAN-SPRINTS.md):

- ~~IMDS alcanzable desde toda la red de pods~~ **CERRADA (2026-08-11)**:
  CiliumClusterwideNetworkPolicy deniega `169.254.169.254` a todos los pods
  excepto el EBS CSI (`platform/policies/`), verificada en el smoke con
  drops de Hubble — incluida la comprobación anti-falso-negativo de la
  excepción (caché STS ~1h).
- ~~Exposición del Gateway por NodePort~~ **CERRADA (2026-08-16, S2-2)**:
  NLB internet-facing en passthrough, NodePort 30443 solo desde el SG del
  NLB, prueba negativa en el smoke; Grafana pasó a port-forward.
- **Sin resiliencia zonal** (una AZ, cross-zone off): la pieza 3 entregó HA
  **de nodo** (3 CPs, etcd stacked, misma AZ) — perder la AZ sigue matando
  el cluster (camino: restore HA desde S3, runbook probado). Deuda
  consciente post-S2; el comentario que prometía "zonal en la pieza 3"
  queda corregido (brief S2-3, decisión 5).
- **Acoplamiento app/API en el NLB único** (ADR-007): una mutación mala del
  NLB afecta a la entrada de aplicación Y al endpoint del API a la vez.
  Declarado y aceptado en lab; un NLB dedicado por plano es el camino si
  esto dejara de ser un lab.
- ~~Ingreso sin e2e probado~~ **CERRADA (2026-08-15)**: e2e exterior en la
  coronación de S1 — `POST /shipments` HTTP 201 por el Gateway con TLS/SNI
  desde fuera del cluster, y gRPC (`CalculateRoute`) por la GRPCRoute;
  evidencia en [HANDOFF.md](HANDOFF.md). La exposición es el NLB desde S2-2.
- **Auditoría de sesiones: parcial hasta configurar el logging.** CloudTrail
  registra *que* se abrió una sesión y quién, pero **el contenido de la shell
  solo queda grabado si se activa el logging de Session Manager** (S3 o
  CloudWatch, con su preferencia de cifrado). Mientras no esté, decir "shell
  auditada" sería exagerar: es *acceso trazado*, no *sesión grabada*.
- **Strimzi 1.2.0-rc1 en camino** (deuda de versión, NO de la pieza 4): el
  chart publicado ya va por 1.2.0-rc1 mientras nosotros pinamos 1.1.0, que
  además **no declara techo de Kubernetes** en ninguna fuente localizable
  (su última declaración es un suelo, "1.30 and newer", de la 0.51). En la
  pieza 4 se trata como riesgo gestionado con pre-flight de datos; el
  upgrade del operador es trabajo posterior, no un cuarto upgrade encadenado.
- **API 6443 pública (por el NLB desde S2-3)** y **kubeconfig admin en SSM**
  (ya solo break-glass, ADR-005) — aceptable en lab efímero, inaceptable en
  cualquier otro contexto. Desde ADR-007 los CPs ya no exponen 6443 al mundo
  (solo al SG del NLB); la puerta pública es el listener del NLB.
- **Egress a la VIP del Gateway no es restringible por CNP del cliente**: el
  tráfico a la LB del Gateway se redirige a Envoy (`to-proxy`) antes de la
  egress policy, así que una CNP de egress ni la puerta ni hace falta
  (INCIDENTS #10). `allowedRoutes` limita **la propiedad de rutas** (qué ns
  puede adjuntar HTTPRoutes — aquí `logistics`), no **la autorización de
  peticiones** (qué pods pueden enviar tráfico por el Gateway); no sustituye
  al control de egress. Riesgo aceptado en el MVP: no hay requisito de aislar
  entre sí a los clientes *dentro* de `logistics`. Control futuro: L7/auth en
  el Gateway + policies por servicio, Fase 1.5.
- **Egress S3 de los pods PG = `world:443`** (fix de INCIDENTS #15): abre
  todo el 443 saliente desde la capa de DATOS — un canal de exfiltración
  que contradice la postura zero-trust de la casa. Refinamiento **ratificado
  en el cruce final y SUBIDO a primera tarea de S3**: VPC *gateway* endpoint
  de S3 (coste cero) + regla por prefix-list en el SG (`pl-…` del endpoint;
  la CNP de Cilium no referencia prefix-lists — su enforcement queda en la
  capa SG/rutas, y el estrechado de la CNP a CIDRs de S3 es opcional
  encima). Elimina el tránsito por IGW y abarata el transfer de backups.
- **Kafka sin backup — decisión de alcance de S2-1, ahora deuda declarada**:
  la pieza cubre etcd y PG; los eventos de Kafka son efímeros por diseño
  (los topics son recurso de plataforma y se recrean; el estado de negocio
  vive en PG). Si algún día un topic carga estado que importe, entra
  MirrorMaker/tiered storage — decisión consciente, no olvido.
- **Rotación manual de las access keys de barman** (usuario `cnpg-backup`)
  hasta External Secrets (S3): crear segunda key → sobrescribir el parámetro
  SSM persistente → `make platform` (el Secret lleva el label
  `cnpg.io/reload: "true"` — label, no annotation —, CNPG lo recarga sin
  rollout) → verificar WAL → borrar la vieja
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
- **Subred pública sin NAT** y **workers spot** — tradeoffs de coste
  documentados que sobreviven a ambos sprints.
- **Token de join con TTL 24h** — workers que se unan más tarde necesitan
  token nuevo (`docs/troubleshooting.md`).
- **Flujo humano SSO de `jm-dev` NO ejercitado — sin evidencia.** El smoke
  prueba el camino IAM con roles asumidos por la identidad de CI, no el login
  interactivo de un humano. Y ojo con la prueba equivocada: el
  `ForbiddenException: No access` que registra
  [platform/access/README.md](../platform/access/README.md) es un rechazo de
  **Identity Center** por sesión de navegador, no el `Forbidden` de **RBAC de
  Kubernetes** que exige el criterio de aceptación. Se leen igual y no lo son:
  dar el primero por bueno validaría el módulo con la prueba equivocada. La
  verificación válida es un login real como `jm-dev` que llegue hasta un
  `kubectl` denegado **por el API server**.
- **Endpoint de readiness por nodo: no existe** (INCIDENTS #20). El health
  check del NLB es TCP contra el NodePort, que Cilium programa con
  independencia de la salud del datapath, así que no puede detectar un nodo
  que dejó de servir. El fix —un endpoint agregador por nodo— sigue sin
  implementar; hay un prototipo en `platform/node-readiness/` que NO está
  desplegado. Límite abierto, no cerrado.

## 6. Historial de incidencias

Ver [INCIDENTS.md](INCIDENTS.md) — 17 incidencias con causa raíz y fix (4 del
montaje manual, 3 de la automatización).
