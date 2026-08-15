# HANDOFF — Sprint 1 coronado (2026-08-15)

Estado de entrega del Sprint 1 y punto de entrada para el Sprint 2. El
criterio de coronación ([PLAN-SPRINTS.md](PLAN-SPRINTS.md)) se cumplió
**punto por punto y observado en real**, no solo por checks internos.

## Criterio de coronación → evidencia del 15-ago

| Criterio | Evidencia |
|----------|-----------|
| `make apply` → cluster completo sin intervención manual | Run de Apply 31880994078: 47 recursos desde estado vacío, plataforma instalada, smoke 38/38, 18 min |
| App respondiendo por el Gateway con TLS | E2E **exterior** (fuera del cluster): `POST /shipments` → HTTP 201 con pinning de clave pública y SNI `shipments.logistics.lab` (shipment `CORONATION-001`, id `f12833dd…`); `grpcurl` lista e invoca `CalculateRoute` vía la GRPCRoute `routing.logistics.lab` sobre TLS |
| Eventos fluyendo por Kafka | Histórico del envío con envelope completo: `shipment.created` + `route.calculated` (`valid:true`, 5 ms entre eventos); topics con 2.721 mensajes cada uno en simetría creación↔ruta |
| Datos en PG | 902 shipments / 1.804 shipment_events en `logistics` (primaria `logistics-pg-1`), 2 eventos por envío |
| Grafana mostrando métricas de la app | `logistics_service_info` de los 4 servicios en Prometheus, Grafana sirviendo en el NodePort |

## Qué pasó por el camino (todo registrado)

- **INCIDENTS #12**: el primer deploy real murió en `AssumeRoleWithWebIdentity`
  — logistics-lab emite el subject OIDC **ID-qualified** (inmutable,
  `repo:org@id/repo@id`) y la trust solo casaba el esquema clásico. Fix en
  PR #42 (`app_repo_ids`, ambos esquemas, solo main+tags), aplicado y
  verificado con el deploy siguiente.
- **Bump de grpc por CVE** (Repo 2): el escaneo de Trivy del pipeline bloqueó
  el push hasta subir la dependencia — la puerta de supply-chain trabajando
  en su primer día real.
- **Deploy ×2 idempotente**: el segundo `workflow_dispatch` sobre el mismo
  estado terminó verde reutilizando los SHA inmutables ya publicados.
- **`make smoke-app-contract GITHUB_SHA=c39bde15…` verde**: 4 servicios
  Ready con imagen traída de ECR **por digest**, `up==1` y
  `logistics_service_info` con muestras en los 4.

## Cómo operar esto (los runbooks)

- Ciclo diario post-apply (logins SSO, kubeconfig, refresh de variables de
  Repo 2): [RUNBOOK-post-apply.md](RUNBOOK-post-apply.md)
- Qué login necesita cada target de make: [CLUSTER.md](CLUSTER.md) §4
- Destroy: volúmenes EBS huérfanos del CSI + borrar `K8S_SERVER` en
  logistics-lab: [troubleshooting.md](troubleshooting.md)

## Siguiente: Sprint 2 — Road to go-live

Por orden ([PLAN-SPRINTS.md](PLAN-SPRINTS.md)): backups con restore probado
(primero, nunca tocar etcd sin backup) → NLB de entrada → HA del control
plane → upgrade en vivo. Más la automatización de los dos residuos del
destroy (EBS huérfanos, variable stale de Repo 2).
