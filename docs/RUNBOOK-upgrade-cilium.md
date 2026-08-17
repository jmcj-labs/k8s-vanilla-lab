# RUNBOOK — 4a: Cilium 1.19.6 → 1.20.x

**Pieza**: S2-4, primer movimiento · **ADR**: [ADR-008](decisions/ADR-008-upgrade-path.md)
**Estado**: ESQUELETO — se completa con tiempos y evidencia al ejecutarlo.

> Una sola variable en este movimiento: **Cilium**. Las CRDs de Gateway API
> se quedan en v1.2.1 hasta 4b, a propósito, para que el testigo pueda
> atribuir cualquier fallo a un único cambio.

## Antes de empezar

| Comprobación | Cómo | Bloquea |
|---|---|---|
| Patch disponible | `gh api repos/cilium/cilium/releases --jq '.[].tag_name' \| grep 1.20` | Preferir 1.20.1; con 1.20.0, validación reforzada |
| Testigo desplegado | Repo 2 desplegado y respondiendo | Sí |
| Snapshot etcd fresco | Job desde el CronJob `etcd-backup` | Sí |
| CNPs sin reglas L7 | `grep -rn "rules:" platform/policies/` → vacío | Verificado: no tenemos |
| `CiliumNodeConfig` v2alpha1 | `kubectl get ciliumnodeconfigs -A` | Migrar a v2 si existe alguno |

## Ejecución

```bash
# Terminal A — testigo abierto ANTES de tocar nada
bash scripts/witness-traffic.sh start "4a-cilium-1.20"

# Terminal B — pre-flight oficial de Cilium y upgrade
cilium upgrade --version 1.20.x   # o helm upgrade preservando NUESTROS values
```

**Values que NO se pueden perder** (si se van, se rompe la pieza 2 o la 3):

```
kubeProxyReplacement=true          # KPR estricto: sin kube-proxy no hay red
k8sServiceHost=<DNS del NLB>       # ADR-007: jamás una IP de nodo
k8sServicePort=6443
gatewayAPI.enabled=true
gatewayAPI.externalTrafficPolicy=Cluster
hubble.relay.enabled=true
hubble.ui.enabled=true
ipam.mode=kubernetes
```

## Verificación (por este orden)

1. `kubectl -n kube-system rollout status ds/cilium` — todos los agentes al día.
2. `cilium-dbg status` → `KubeProxyReplacement: True`.
3. **El Gateway sigue vivo con CRDs viejas**: `shared-gw` `Programmed=True`.
   *Aquí es donde se vería el riesgo del orden 4a→4b* (Cilium 1.20 documenta
   Gateway API v1.6.1 y arranca con v1.2.1). Si el Gateway cae, **rollback**.
4. LB-IPAM sigue asignando: el Service del Gateway conserva su IP.
5. Hubble responde.
6. `bash scripts/witness-traffic.sh stop` → **veredicto `enviadas == exitosas`**.

## Rollback

Minor consecutiva y soportada: volver a **1.19.6** con los mismos values.
Si el testigo registró un solo fallo, se revierte y se investiga; no se
"sigue a ver si mejora".

## Tiempos (pendiente de ejecución)

| Fase | Tiempo |
|---|---|
| Rollout del DaemonSet | — |
| Ventana del testigo | — |
