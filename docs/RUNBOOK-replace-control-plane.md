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

0. **Lock atómico** (`ConfigMap cp-replacement-lock` en `kube-system`): dos
   ceremonias no pueden solaparse — `kubectl create` sobre un objeto que ya
   existe falla, y esa exclusión la arbitra el API server, no la shell. Sin
   él, dos ejecuciones podrían ver un cluster sano cada una y retirar **dos**
   miembros. Se libera con `trap` incluso si el script aborta; si quedó
   huérfano: `kubectl -n kube-system delete configmap cp-replacement-lock`.
1. **Precondición ligada al índice** — solo dos formas son seguras:
   - **3/3 sanos** → reemplazo *planificado* de cualquier índice.
   - **exactamente 2/3 sanos y el índice pedido ES la baja** (Node NotReady
     o máquina ausente) → reemplazo de *recuperación*.

   Cualquier otra combinación aborta: dos bajas ya no es un reemplazo
   (es un restore), y pedir sustituir un nodo **sano** mientras otro está
   caído dejaría el cluster en 1/3.
2. **Identifica el nodo** por `providerID` → instance-id (el mapeo fiable;
   los hostnames varían), desde EC2 y, si la instancia ya no existe, **desde
   el state de Tofu**. Nunca continúa sin saber a qué miembro entierra: si el
   Node ya no está registrado, localiza al huérfano *por eliminación* (el
   miembro etcd cuyo nombre no corresponde a ningún Node vivo) y aborta si
   hay más de uno.
3. **Plan guardado e inspeccionado — ANTES de degradar nada**: `tofu plan
   -replace=<addr> -out=…` y comprobación sobre el JSON de que **ninguna
   otra instancia** se destruye o reemplaza. Si el plan falla o resulta
   inaceptable, la ceremonia aborta con **el cluster intacto**: etcd conserva
   todos sus miembros y no se ha borrado ningún Node. Ese orden es
   deliberado — abortar después de haber retirado un miembro cobraría un
   cluster de 2 como precio de un ensayo fallido.
4. **Renueva el material de join** (certificate-key 2h + token 24h) desde un
   superviviente — salvo `SKIP_RENEW=1`, que existe para el drill.
5. **Retira el miembro etcd muerto** (`etcdctl member remove`) y **borra el
   Node** viejo. A partir de aquí el cluster está degradado a propósito, con
   el plan ya aprobado.
6. **Aplica el plan aprobado** tal cual (`tofu apply <plan>`): lo que se
   inspeccionó es lo que se ejecuta.
7. **Vuelve a borrar el Node viejo** tras el apply: entre el primer borrado y
   la terminación real de la máquina, su kubelet puede re-registrarlo.
8. **Cierra con capacidad restaurada y conjuntos EXACTOS** (las invariantes
   del smoke §14, no meros conteos): exactamente 3 Nodes de control plane y
   los 3 Ready · exactamente 3 miembros etcd y los 3 *started* ·
   `etcdctl endpoint health --cluster` sano · y el conjunto de targets
   **registrados** igual al de instance-ids vivos **y todos healthy** (dos
   asertos separados: "3 healthy" ocultaría un cuarto target *draining* de la
   máquina retirada).

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

## Drill de aceptación (pieza 3) — **necesita DOS terminales**

El paso 2 **se queda esperando** hasta 30 minutos a que el reemplazo se una;
la renovación del paso 3 tiene que ocurrir **mientras tanto**, no después. La
ventana es de **6 reintentos separados 120s** (~12 min desde el primer fallo
de join): renovar dentro de esa ventana y el reintento en curso recoge la
clave fresca; fuera de ella, el bootstrap se rinde y hay que repetir.

**Terminal A** — deja el reemplazo corriendo y bloqueado a la espera:

```bash
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
# 1. Invalida el material de CP (equivale a haber pasado las 2h)
kubectl -n kube-system delete secret kubeadm-certs

# 2. Reemplaza SIN renovar — el join fallará y reintentará
SKIP_RENEW=1 bash scripts/replace-control-plane.sh 0
```

**Terminal B** — vigila el fallo y renueva dentro de la ventana:

```bash
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
# Espera a ver el primer fallo en el nodo nuevo
make ssh-cp CP_INDEX=0        # sudo tail -f /var/log/k8s-cp-bootstrap.log
#   → "Join attempt 1/6 ... failed" · "retrying in 120s (re-fetching certificate-key)"

# 3. Renueva: el reintento en curso recoge la clave fresca (≤120s)
bash scripts/renew-cp-certificate-key.sh
```

De vuelta en **Terminal A**: la ceremonia continúa sola y cierra con los
conjuntos exactos. Después, la verificación independiente:

```bash
# 4. Cierre completo del cluster, no solo del reemplazo
make smoke-test
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
- **"another control-plane replacement is in flight"**: hay una ceremonia
  viva (el mensaje dice quién y desde cuándo) o murió dejando el lock. Si se
  confirma que no hay ninguna corriendo:
  `kubectl -n kube-system delete configmap cp-replacement-lock`.
- **"plan inspection refused this plan"**: el plan tocaba otras instancias.
  **No se aplicó nada y el cluster sigue intacto** — la inspección ocurre
  antes de retirar el miembro etcd (paso 3, no 5). Revisar el `tofu plan`
  completo a mano: normalmente significa que hay cambios pendientes sin
  relación con el reemplazo, y esos deben aplicarse (o revertirse) por
  separado antes de repetir la ceremonia.
- **"cannot read cluster_info from the tofu state"**: la ceremonia no
  adivina cuántos CPs debería haber — sin ese dato no puede juzgar ninguna
  precondición. Causas típicas: credenciales caducadas, `make init`
  pendiente, backend inalcanzable.
