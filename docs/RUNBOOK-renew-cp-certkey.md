# RUNBOOK — Renovación del material de join de CPs (key 2h + token 24h)

**Pieza**: S2-3 (HA del control plane, ADR-007) · **Script**: `scripts/renew-cp-certificate-key.sh`

## Por qué existe

Un `kubeadm join --control-plane` necesita **dos** materiales con vidas
distintas, y renovar uno solo deja el reemplazo atascado en el otro:

| Material | TTL | Dónde vive | Qué pasa al caducar |
|---|---|---|---|
| `certificate-key` | **2h** | SSM `/k8s/<cluster>/cp/certificate-key` | El Secret `kubeadm-certs` desaparece; la clave guardada no descifra nada |
| Bootstrap token (dentro de `join-command`) | **24h** | SSM `/k8s/<cluster>/join-command` | El join no autentica contra la API |

Guardar la clave vieja **no** resuelve nada — el Secret ya no existe; la única
cura es que un CP superviviente **re-suba** los certificados. El script hace
las dos renovaciones en una sola ceremonia.

> El Apply de CI ya acuña token fresco antes de cada apply sobre cluster vivo
> (step *Preflight join token*), así que un reemplazo conducido por Apply
> obtiene el token solo. Esta ceremonia cubre la vía manual y hace la
> precondición **explícita en vez de implícita**.

## Cuándo ejecutarlo

- Antes de recrear un CP (taint/terminate + `tofu apply`) si han pasado >2h
  desde el bootstrap del cluster o desde la última renovación.
- Cuando un CP de reemplazo esté en bucle de reintentos de join
  (`/var/log/k8s-cp-bootstrap.log` del nodo: "Join attempt N/6 ... failed").
  El bootstrap de join re-lee la clave de SSM en **cada reintento** (cada
  ~120s), así que basta renovar y esperar.

## REGLA DE ORO: los reemplazos, de UNO EN UNO

**Un cambio de IaC nunca debe sustituir varios CPs a la vez.** Con 3 miembros,
el quorum tolera perder **uno**; reemplazar dos simultáneamente destruye el
quorum y convierte el incidente en un restore HA completo
([RUNBOOK-restore-etcd-ha.md](RUNBOOK-restore-etcd-ha.md)).

Antes de cualquier apply que pueda tocar instancias de CP (cambio de AMI,
de `instance_type`, de `user_data` sin `ignore_changes`, de subred…):

```bash
cd tofu/envs/lab && tofu plan | grep -c "aws_instance.control_plane.*must be replaced"
```

- **0** → adelante.
- **1** → adelante; espera a que el nodo vuelva (smoke §14: etcd 3/3) antes
  de otro apply.
- **≥2** → **PARAR**. Serializa: aplica con `-target` sobre un índice,
  espera etcd 3/3, y repite con el siguiente.

El bootstrap del join es **reentrante** (si el nodo ya es un CP sano, sale
con 0 sin tocar nada), pero eso protege del re-run, no de la pérdida
simultánea de quorum: esa parte es disciplina de operación.

## Ceremonia

```bash
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf     # break-glass (make kubeconfig)
bash scripts/renew-cp-certificate-key.sh           # [nodo] opcional como arg 1
```

Qué hace: Job privilegiado `nsenter` fijado a un CP **Ready** →
`kubeadm init phase upload-certs --upload-certs` + `kubeadm token create
--ttl 24h` → publica clave y `join-command` reconstruido (endpoint y CA hash
preservados) **desde el propio nodo** (role de instancia del CP). Ni la clave
ni el token **aparecen nunca en logs** — ni del Job ni del script.

Verificación: el mensaje final del Job (`join material renewed`) y, si había un
CP esperando, su join completa en el siguiente reintento (≤120s).

## Notas de seguridad

- El path SSM `cp/` (certificate-key, joined-count) está **excluido del role de
  worker**, que enumera ARNs exactos (`join-command`, `ca-cert-hash`): con la
  clave, cualquier poseedor del token de join podría elevarse a control plane
  (hallazgo de Codex, S2-3). **No es "exclusivo del role de CP"**: el role
  OIDC de CI lee `/k8s/*` y ya custodia el kubeconfig admin — un privilegio
  estrictamente mayor —, así que estrecharlo no añadiría seguridad real.
- El TTL de 2h es una propiedad de seguridad, no una molestia: material de join
  de control plane de vida corta. No intentar alargarlo.
