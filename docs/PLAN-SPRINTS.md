# logistics-lab — Plan de sprints (cerrado 10 ago 2026)

Proyecto: cluster K8s vanilla (evolución de `k8s-vanilla-lab`) + aplicación logistics-lab desplegada.
Método: decisiones de diseño en chat (Claude); ejecución de código en Cursor/Claude Code; el repo nunca va por detrás de la realidad.

---

## Sprint 1 — Cluster automático + App MVP (7 días, día 1 = 10 ago) — ✅ CERRADO 15-ago

**Entregables:** Repo 1 (`k8s-vanilla-lab` evolucionado, cluster completo con `make apply`) + Repo 2 (logistics-lab MVP desplegado).

### Día 1-2 — Cluster automático
Evolución de `k8s-vanilla-lab` en main, sin ramas. Cambios (todos validados en la ejecución manual del día 1):
- kubeadm 1.35.x (sin pin de patch), containerd repo Docker
- `skipPhases: addon/kube-proxy` + Cilium `kubeProxyReplacement=true`, `gatewayAPI.enabled=true`, Hubble
- CRDs Gateway API antes del operator de Cilium
- EC2: `http_put_response_hop_limit = 2`; IAM node role + `AmazonEBSCSIDriverPolicy`
- Patch de `providerID` post-init/post-join (kubeadm vanilla no lo setea; el EBS CSI lo necesita)
- `platform/`: EBS CSI (con `controller.region=eu-west-1`), StorageClass gp3 default cifrada, namespaces (infra/data/logistics), cert-manager + ClusterIssuer selfsigned, Gateway compartido, operators CNPG + Strimzi, kube-prometheus-stack
- Smoke test ampliado: 3 nodos Ready · KPR=true · PVC gp3 Bound · Gateway Programmed=True · operators Running
- Cron de destroy nocturno desactivado/ajustado durante el sprint
- Runbook de la ejecución manual + incidentes de primera ejecución en `docs/`

### Día 2 — Sesión de decisiones #1 (chat)
1. Exposición del Gateway: NodePort vs NLB manual vs hostPort (sin cloud-controller no hay LB automático)
2. Sizing cluster PG (CNPG) y Kafka KRaft 1 broker (Strimzi)
3. Topología de namespaces definitiva + NetworkPolicies base
4. Registry de imágenes: ECR vs GHCR → **CERRADA (2026-08-12): ECR** (tags
   inmutables por SHA, pull por instance role sin pull-secrets, roles CI
   separados infra/app; ver [ADR-006](decisions/ADR-006-ecr-registry.md))
5. Servicios del MVP (propuesta: shipments-api, routing, tracking-events + traffic-generator)

### Día 3-5 — logistics-lab MVP (Cursor/Claude Code)
- Servicios Go acordados, regla de 400 líneas, instrumentación desde el minuto uno (slog, client_golang, healthchecks)
- Clusters de datos: CNPG PG + Strimzi Kafka
- Helm chart de la app; requests/limits/probes; HTTPRoute con TLS
- CiliumNetworkPolicy básica
- CI de build+push de imágenes

### Día 6 — Despliegue + Sesión de decisiones #2
- App desplegada end-to-end, traffic-generator corriendo
- Sesión #2: qué quedó fuera, ajustes, criterios de "coronado"

### Día 7 — Buffer + cierre
- Smoke tests E2E, README de ambos repos, diagrama de arquitectura del sprint

**Criterio de coronación Sprint 1:** `make apply` → cluster completo sin intervención manual; app respondiendo por el Gateway con TLS; eventos fluyendo por Kafka; datos en PG; Grafana mostrando métricas de la app.

**→ CUMPLIDO y observado en real el 15-ago-2026** — cada punto con su
evidencia (e2e exterior HTTP+gRPC, topics en simetría, filas en PG, métricas
de los 4 servicios) en [HANDOFF.md](HANDOFF.md). Siguiente: Sprint 2.

### Fuera del Sprint 1 (explícito)
Fase 1.5 completa (L7 policies, mesh, Tetragon), los 4 servicios restantes de logistics-lab, OTel Collector/tracing, todo lo del Sprint 2.

---

## Sprint 2 — Road to go-live (semana siguiente)

Secuencia profesional: plataforma → app en staging → **hardening de resiliencia → go-live**. Este sprint es el hardening. Ejecuta Topics 8 (Operaciones) y 9 (Diseño de clúster) del path sobre el cluster con app real encima.

El orden interno importa:

### Microcommit de higiene operativa (al arrancar S2)
- La notificación Slack introducida en el PR #40 debe obtener
  `control_plane_public_ip` de `tofu output -raw` al terminar el apply y
  publicarla como output no sensible del job; `notify-slack` recibe esa EIP y
  añade `:6443`. Así conserva su diseño sin checkout/backend/Tofu y deja de
  descifrar el kubeconfig admin de SSM para obtener un dato público.
- El `awk` actual solo emite el primer valor de `server:`, elimina `https://` y
  no vuelca certificado ni clave. No hay filtración observada; el cambio se
  justifica por mínima superficie y separación de responsabilidades, no por una
  fuga activa.

### 1. Backups con restore probado (primero — nunca tocar etcd sin backup) — 🔨 IaC lista (15-ago), drills pendientes del próximo apply
- etcd: CronJob → snapshot a S3 (patrón BP-005 del Review EPO) + **restore ejecutado y documentado**
- Postgres: CNPG backups a S3 (barman) + restore probado
- Regla: sin restore probado, no es un backup — es una esperanza
- Implementación (brief #S2-1): stack `tofu/envs/persistent` (bucket +
  usuario IAM barman), CronJob etcd 6h (instance role, write-only `etcd/*`),
  CNPG `barmanObjectStore` (WAL continuo + base diario, keys desde SSM
  persistente), smoke ampliado (backup path en cada apply), drills en
  `docs/RUNBOOK-restore-etcd.md` / `docs/RUNBOOK-restore-cnpg.md` — se
  ejecutan y cronometran con el cluster levantado; la pieza corona cuando
  ambos testigos vuelven (ConfigMap + `CORONATION-001`).

### 2. LB de entrada real
- NLB delante del Gateway (target group a los workers)
- Sustituye la decisión provisional de exposición del Sprint 1

### 3. HA del control plane
- 3 CPs con etcd en quórum (tolera caída de 1)
- Endpoint estable del API (decidir: NLB interno vs alternativa) — necesario ANTES de unir el segundo CP
- Rediseño de IaC: es un cambio estructural, no un add-on
- Contraste honesto documentado con managed (EKS/GKE) — material Review EPO

### 4. Upgrade del cluster en vivo (último — con HA ya no hay ventana de API caída)
- `kubeadm upgrade` 1.35.x → siguiente minor disponible
- drain/cordon nodo a nodo, PDBs de la app respetados
- **Prueba de oferta:** app sirviendo tráfico del traffic-generator durante TODO el upgrade, sin downtime observable, con Grafana de testigo
- Rotación de certificados incluida

**Criterio de coronación Sprint 2:** restore de etcd y de PG demostrados; entrada por NLB; API sobrevive a la caída de 1 CP; upgrade minor completado con la app sirviendo tráfico.

---

## Después del Sprint 2
Retomar el path donde manda el mapa: Fase 1.5 (Cilium a fondo: L7, Hubble avanzado, mesh, Tetragon) y luego Fase 2 completa (resto de servicios, OTel/tail-sampling, operator con Kubebuilder). El pseudo-gap de IMDS desde pods (mitigado con region/providerID) se investiga en Fase 1.5 — probable interacción con masquerading de Cilium.

## Desviaciones registradas

- **Tag-bump del deploy fuera del MVP** (12 ago 2026): el despliegue de Repo 2
  usa `helm --set imageTag=<SHA>` con refresh manual de `K8S_SERVER`/`K8S_CA_DATA`
  tras cada recreate. El GitOps declarativo (ArgoCD, imagen fijada en Git,
  auto-sync) vuelve en Sprint 3. Deuda consciente documentada en CLUSTER.md §5.

## Deuda consciente que sobrevive a ambos sprints
- Subred pública sin NAT (tradeoff lab documentado)
- Workers spot (fallback on-demand vía variable)
- Sin OTel/tracing hasta Fase 2
