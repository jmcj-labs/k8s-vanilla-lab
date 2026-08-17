# RUNBOOK — 4c: Kubernetes 1.35.7 → 1.36.3 en vivo (HA)

**Pieza**: S2-4, tercer movimiento · **ADR**: [ADR-008](decisions/ADR-008-upgrade-path.md)
**Estado**: ESQUELETO — se completa al ejecutarlo.

> Destino **1.36.3**, verificado en el índice apt del que instalan los nodos
> (`pkgs.k8s.io`, rama v1.36), no en la web — que daba 1.36.2 y estaba
> vencida. **Reverificar el día de ejecutar.**

## Pre-flights — todos fail-closed, todos ANTES de tocar CP-0

| Pre-flight | Comando | Si falla |
|---|---|---|
| **cgroup v2** en los 6 nodos | `bash scripts/preflight-cgroup-v2.sh` | **ABORTAR**: 1.36 rechaza v1 y el kubelet no arrancaría |
| Operadores contra 1.36 | ver ADR-008 | 5 acreditan; Strimzi es riesgo gestionado (abajo) |
| Snapshot etcd fresco | Job desde `cronjob/etcd-backup` | ABORTAR: es el único rollback catastrófico |
| Cilium ya en 1.20.x | `cilium version` | ABORTAR: 1.19 no acredita 1.36 |
| Gateway API ya en v1.6.x | `kubectl get crd gateways...` | ABORTAR: orden contractual |

### Pre-flight de datos (Strimzi, riesgo gestionado)

Strimzi 1.1.0 **no declara techo** de Kubernetes (su última declaración es un
suelo: *"1.30 and newer"*). No es bloqueante, es riesgo con red:

- Los workers se drenan **de uno en uno**, respetando los PDB.
- Tras CADA worker: **Kafka `Ready` antes de seguir**.
- Si el **primer** broker sobre kubelet 1.36 falla → **PARAR ahí**, con dos
  brokers sanos. RF3 con `min.insync.replicas=2` lo sostiene.
- Un worker que no drena por PDB es **una señal, no un obstáculo que forzar**.

## Ejecución

```bash
bash scripts/witness-traffic.sh start "4c-k8s-1.36.3"
```

**Orden HA (kubeadm)** — nunca dos APIs a la vez:

1. **CP-0**: `kubeadm upgrade plan` → `kubeadm upgrade apply v1.36.3 --skip-phases=addon/kube-proxy`
2. **CP-1**, luego **CP-2**: `kubeadm upgrade node` (uno a uno)
3. En cada CP: drenar, actualizar kubelet/kubectl, `uncordon`
4. **Workers uno a uno**: drain (respetando PDB) → kubelet → uncordon → **Kafka y CNPG Ready antes del siguiente**

> `--skip-phases=addon/kube-proxy` en **todos** los comandos kubeadm: somos
> kube-proxy-free y kubeadm lo recrearía. Prueba negativa al final: **cero
> pods kube-proxy**.

## Verificación

1. Los 6 nodos en `v1.36.3`.
2. **Cero** pods kube-proxy.
3. Todos los operadores Ready.
4. **Certificados**: `kubeadm upgrade` los renueva — comprobar que la **CA es
   idéntica**, que serial y `notAfter` son nuevos, y que el **SAN conserva el
   DNS del NLB**. Republicar el break-glass renovado en SSM. Como la CA no
   cambia, el kubeconfig sintético de logistics-lab **no debería tocarse**:
   confirmarlo, no suponerlo.
5. `bash scripts/witness-traffic.sh stop` → **`enviadas == exitosas`**.
6. **CORONATION-00N creado DURANTE el upgrade**, no antes.

## Después

Actualizar `bootstrap/common.yaml` a la serie 1.36 — si no, **el próximo nodo
nace en 1.35** y el siguiente apply deshace la pieza.

## Rollback

**kubeadm no soporta downgrade limpio de minor.** El rollback catastrófico es
el **restore HA** de la pieza 3 desde el snapshot previo
([RUNBOOK-restore-etcd-ha.md](RUNBOOK-restore-etcd-ha.md), 193 s medidos).

## Tiempos y ventanas (pendiente)

| Nodo | Ventana | Targets healthy durante |
|---|---|---|
| CP-0 | — | ≥2 |
| CP-1 | — | ≥2 |
| CP-2 | — | ≥2 |
| workers ×3 | — | — |
