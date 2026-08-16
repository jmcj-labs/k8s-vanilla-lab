# RUNBOOK — Renovación del certificate-key (join de control planes)

**Pieza**: S2-3 (HA del control plane, ADR-007) · **Script**: `scripts/renew-cp-certificate-key.sh`

## Por qué existe

`kubeadm` cifra los certificados del control plane en el Secret `kubeadm-certs`
con una clave (el *certificate-key*) cuyo TTL es **2 horas**. Pasado ese plazo
caducan **las dos cosas**: el Secret desaparece del cluster y la clave publicada
en SSM (`/k8s/<cluster>/cp/certificate-key`) deja de descifrar nada.

Consecuencia operativa: un CP de reemplazo que arranque **más de 2h después**
del último upload no puede completar `kubeadm join --control-plane`. Guardar la
clave vieja en SSM **no** resuelve nada — el Secret ya no existe; la única cura
es que un CP superviviente **re-suba** los certificados y publique clave fresca.

## Cuándo ejecutarlo

- Antes de recrear un CP (taint/terminate + `tofu apply`) si han pasado >2h
  desde el bootstrap del cluster o desde la última renovación.
- Cuando un CP de reemplazo esté en bucle de reintentos de join
  (`/var/log/k8s-cp-bootstrap.log` del nodo: "Join attempt N/6 ... failed").
  El bootstrap de join re-lee la clave de SSM en **cada reintento** (cada
  ~120s), así que basta renovar y esperar.

## Ceremonia

```bash
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf     # break-glass (make kubeconfig)
bash scripts/renew-cp-certificate-key.sh           # [nodo] opcional como arg 1
```

Qué hace: Job privilegiado `nsenter` fijado a un CP **Ready** →
`kubeadm init phase upload-certs --upload-certs` → publica la clave en
`/k8s/<cluster>/cp/certificate-key` **desde el propio nodo** (role de instancia
del CP; el path `cp/` es exclusivo de ese role). La clave **nunca aparece en
logs** — ni del Job ni del script.

Verificación: el mensaje final del Job (`certificate-key renewed and published`)
y, si había un CP esperando, su join completa en el siguiente reintento (≤120s).

## Notas de seguridad

- El path SSM `cp/` (certificate-key, joined-count) es **solo del role de CP**:
  el role de worker enumera ARNs exactos (`join-command`, `ca-cert-hash`) y no
  puede leerlo — con la clave, cualquier poseedor del token de join podría
  elevarse a control plane (hallazgo de Codex, S2-3).
- El TTL de 2h es una propiedad de seguridad, no una molestia: material de join
  de control plane de vida corta. No intentar alargarlo.
