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

PENDIENTE — 3 CPs con joins secuenciados; se vigila el **fail-open** del NLB
durante el `kubeadm init` (tradeoff aceptado en el cruce 4: si kubeadm
resulta intermitente, escalonar los attachments).

## 3. Smoke completo con §14

PENDIENTE — 6/6 nodos · etcd 3/3 · targets API 3/3 · negativa `:6443` en las
3 IPs públicas de CP · coherencia de endpoint · authenticator 3/3.

## 4. Drill de pérdida: parar CP-0 (el fundador)

PENDIENTE — escrituras/lecturas de API, autenticación IAM, aplicación
intacta y backup de etcd ejecutándose desde otro CP.

## 5. Drill de reemplazo con `kubeadm-certs` invalidado

PENDIENTE — dos terminales; renovación dentro de la ventana de 6 reintentos.

## 6. Restore HA con testigo recuperado

PENDIENTE — tiempos al runbook.

## 7. Segundo apply con plan vacío

PENDIENTE

## 8. Coste real medido

PENDIENTE — Cost Explorer → `CLUSTER.md` §FinOps.
