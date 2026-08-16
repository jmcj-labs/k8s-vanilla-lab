# RUNBOOK — Sustitución de un control plane (recuperar capacidad HA)

**Pieza**: S2-3 (ADR-007) · **Script**: `scripts/replace-control-plane.sh` ·
**Relacionados**: [renovación del material de join](RUNBOOK-renew-cp-certkey.md) ·
[restore HA](RUNBOOK-restore-etcd-ha.md)

> Sobrevivir a perder un CP y **recuperar** la capacidad HA son cosas
> distintas. Con 2 de 3 miembros el cluster sirve, pero ya no tolera otro
> fallo: hasta que el tercero vuelve, se está operando sin red.

## Por qué no basta con `tofu apply`

Recrear la instancia es la mitad fácil. Sin la ceremonia quedan dos cadáveres:

- **El miembro etcd muerto**: etcd no olvida. Si el reemplazo entra sin
  retirar al difunto, la membresía queda en **4 miembros (3 vivos, 1 muerto)**
  — el smoke 3/3 falla y, peor, el umbral de quorum sube a 3: **el siguiente
  fallo simple tumba el cluster**.
- **El Node viejo**: objeto `NotReady` con sus taints, contaminando el
  scheduling y los conteos.

Y un detalle de IaC: `-target` **no** basta. Un apply dirigido puede saltarse
el `aws_lb_target_group_attachment`, dejando el nodo nuevo fuera del endpoint
del API. La ceremonia usa **`-replace` con plan completo**, que sí recalcula el
attachment (su `target_id` cambia).

## Qué hace la ceremonia

```bash
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
bash scripts/replace-control-plane.sh <índice>     # 0, 1 o 2
```

1. **Un solo reemplazo**: aborta si hay más de un CP no-Ready (con 3 miembros
   el quorum tolera exactamente uno; dos es un restore, no un reemplazo).
2. **Identifica el nodo** por `providerID` → instance-id (el mapeo fiable;
   los hostnames varían), incluso si la instancia ya está terminada.
3. **Renueva el material de join** (certificate-key 2h + token 24h) desde un
   superviviente — salvo `SKIP_RENEW=1`, que existe para el drill.
4. **Retira el miembro etcd muerto** (`etcdctl member remove`) y **borra el
   Node** viejo.
5. **Recrea la instancia** con `tofu apply -replace=module.control_plane.aws_instance.control_plane[N]`.
6. **Cierra con capacidad restaurada**: espera 3/3 nodos Ready, 3/3 miembros
   etcd *started* y 3/3 targets healthy en el TG del API.

## El índice 0 no es especial (ya no)

El fundador se elige **en tiempo de ejecución, no en el plan**. El script
`bootstrap/control-plane.yaml` (renderizado solo en el índice 0) comprueba
`cp/joined-count` en SSM: si existe, ya hay cluster → **sale sin hacer nada** y
el script de join —renderizado en **todos** los índices— hace el trabajo.

Consecuencias que conviene tener presentes:

- Un índice 0 reconstruido **se une**, nunca reinicializa. Antes, el selector
  estático `count.index == 0 ? init : join` habría creado un segundo cluster
  encima del vivo.
- El contador `cp/joined-count` es **monótono**: el reemplazo de un índice bajo
  no baja la barrera que ya pasaron los altos.
- El script de join sale con 0 si el nodo ya tiene
  `/etc/kubernetes/manifests/kube-apiserver.yaml` — así el índice 0 recién
  inicializado no intenta unirse a sí mismo.

## Drill de aceptación (pieza 3)

Demuestra la ruta de caducidad end-to-end:

```bash
# 1. Deja caducar la clave (>2h desde el bootstrap) o invalida el Secret:
kubectl -n kube-system delete secret kubeadm-certs

# 2. Reemplaza SIN renovar — el join debe fallar y reintentar
SKIP_RENEW=1 bash scripts/replace-control-plane.sh 0
#    (en el nodo nuevo: /var/log/k8s-cp-bootstrap.log → "Join attempt N/6 ... failed")

# 3. Renueva: el reintento en curso recoge la clave fresca (≤120s)
bash scripts/renew-cp-certificate-key.sh

# 4. Cierre: 3/3 nodos, 3/3 etcd, 3/3 targets
bash scripts/smoke-test.sh      # o make smoke-test
```

## Tiempos (drill del AAAA-MM-DD — pendiente de ejecución)

| Fase | Tiempo |
|------|--------|
| Retirada de miembro + Node | — |
| `tofu apply -replace` | — |
| Bootstrap + join del reemplazo | — |
| Hasta 3/3 etcd y 3/3 targets | — |

## Si algo va mal

- **El nuevo nodo no aparece**: `/var/log/k8s-cp-bootstrap.log` en la
  instancia (`make ssh-cp CP_INDEX=<n>`). Causa típica: material de join
  caducado → ejecutar la renovación.
- **Membresía con 4 miembros**: se saltó el paso 4; retirar a mano con
  `etcdctl member remove` desde un superviviente y volver a comprobar.
- **Dos o más CPs caídos**: esto ya no es un reemplazo —
  [restore HA](RUNBOOK-restore-etcd-ha.md).
