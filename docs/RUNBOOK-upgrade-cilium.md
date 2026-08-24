# RUNBOOK — 4a: Cilium 1.19.6 → 1.20.1

**Pieza**: S2-4, **SEGUNDO** movimiento (reordenado 2026-08-23) · **ADR**: [ADR-008](decisions/ADR-008-upgrade-path.md)
**Estado**: ESQUELETO — se completa con tiempos y evidencia al ejecutarlo.
**PRERREQUISITO DURO — GATE EJECUTABLE, no una nota**. Sin las CRDs en
v1.6.1 el operador de 1.20.1 no arranca su controlador de Gateway API y la
puerta muere 18 s después de que helm diga `deployed` (ejecución fallida del
23-ago; ADR-008 §1, INCIDENTS #17 8ª cara). Comprobarlo **antes de nada**:

```bash
# Gates 1/2 — una sola implementación canónica: siete kinds sirviendo v1,
# TLSRoute sirviendo exactamente v1+v1alpha2+v1alpha3 y bundle v1.6.1 en los
# siete CRDs. Cada conjunto lleva recuento positivo; no hay copia jsonpath
# inline que pueda volver a divergir del gate probado.
bash scripts/verify-cilium-120-schema.sh

# Gate 3 — el controlador de 1.19 sigue TRABAJANDO sobre esas CRDs.
bash scripts/verify-gateway-controller.sh pre-4a

echo "✓ 4b confirmado: 4a puede proceder"
```

Los tres son la misma pregunta hecha de tres maneras, y la tercera es la
única que prueba trabajo en vez de presencia.

**Destino fijado**: **v1.20.1**, publicado 2026-08-18T10:36:16Z (`prerelease=false`,
`draft=false`), chart Helm 1.20.1 ya en el índice de `cilium/charts`.

> Una sola variable en este movimiento: **Cilium**. Las CRDs de Gateway API
> se quedan en v1.2.1 hasta 4b, a propósito, para que el testigo pueda
> atribuir cualquier fallo a un único cambio.

**El desajuste que 4a tiene que revelar, medido**: el `go.mod` de v1.20.1
fija `sigs.k8s.io/gateway-api v1.6.1` — **idéntico a 1.20.0**, así que el
patch NO mueve esa dependencia. **Ese riesgo se materializó el 23-ago** y
por eso el orden es ahora 4b→4a: `v1.6.1` no era documentación, era un
requisito. Con 4b hecho, este movimiento llega a unas CRDs que ya lo
satisfacen. El detector NO es el campo `Programmed` — resultó ser una caché
rancia; es el **controlador de Gateway API vivo** en el log del operador.

**Del changelog de 1.20.1, lo que toca nuestra superficie** (todo son
correcciones, ninguna acción requerida): arreglo del estado de dirección del
Gateway que reportaba un `<nil>` espurio cuando la primera dirección de
estado de un nodo no es una IP literal —directamente sobre lo que
verificamos—, más una tanda de fixes de gateway-api (precedencia de reglas
HTTPRoute duplicadas, listeners en conflicto, secretos TLS de ListenerSet) y
`envoy: restore http-idle-timeout`. Sin *breaking changes* ni notas de
upgrade: la única entrada de "Major Changes" es documentación de Cluster
Mesh, que no usamos.

## Antes de empezar

| Comprobación | Cómo | Bloquea |
|---|---|---|
| Patch disponible | `gh api repos/cilium/cilium/releases --jq '.[].tag_name' \| grep 1.20` | RESUELTO: 1.20.1 existe desde el 18-ago. El gate de dirección queda abierto |
| Testigo desplegado | Repo 2 desplegado y respondiendo | Sí |
| Snapshot etcd fresco | Job desde el CronJob `etcd-backup` | Sí |
| CNPs sin reglas L7 | `grep -rn "rules:" platform/policies/` → vacío | Verificado: no tenemos |
| `CiliumNodeConfig` v2alpha1 | `kubectl get ciliumnodeconfigs -A` | Migrar a v2 si existe alguno |

## Lo aprendido en el intento fallido del 23-ago

- **Envoy NO va embebido**: el pod `cilium` solo tiene `cilium-agent`, y hay
  un DaemonSet aparte `cilium-envoy`. El chart 1.20.1 sube Envoy de
  `v1.36.9` a `v1.37.5`, así que el upgrade **rueda los dos** y la ventana
  mide también el data-plane del Gateway, no solo el routing del agente.
- **`maxUnavailable=2` en ambos DaemonSets** sobre 6 nodos, pero el NLB solo
  apunta a los **3 workers**: puede llevarse 2/3 de la puerta a la vez, y el
  health check del target group (intervalo 3s, umbral 10) tarda ~30s en
  sacar un target caído. **Bajar a 1 en `cilium-envoy`** para que la ventana
  mida el upgrade y no la política de rollout:
  `--set envoy.updateStrategy.rollingUpdate.maxUnavailable=1`
- **El rollback funciona y está medido**: `helm rollback cilium -n kube-system`
  devolvió a 1.19.6 (revisión 3) y el testigo volvió a `ok` en ~86s.
  **Ojo al `-n kube-system`**: sin él helm busca en `default` y no encuentra
  el release.

## Ejecución

```bash
# Terminal A — testigo abierto ANTES de tocar nada
bash scripts/witness-traffic.sh start "4a-cilium-1.20"

# Terminal B — pre-flight oficial de Cilium y upgrade
cilium upgrade --version 1.20.1   # o helm upgrade preservando NUESTROS values
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
3. **El controlador de Gateway API arrancó** — la verificación que 4a no
   tenía y que le costó la ejecución del 23-ago:
   `kubectl -n kube-system logs deploy/cilium-operator --tail=200 | grep -i "Required GatewayAPI resources"`
   → **vacío**. Si aparece, el controlador NO arrancó: **rollback inmediato**,
   por mucho que `shared-gw` siga diciendo `Programmed=True` (lo dirá: ese
   campo sobrevive a la muerte de su controlador). Solo después mirar el
   Gateway, y comprobar que Envoy tiene listener y no acumula
   `initial fetch timed out`.
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
