# RUNBOOK — 4b: Gateway API CRDs v1.2.1 → v1.6.x (escalonado)

**Pieza**: S2-4, **PRIMER** movimiento (reordenado 2026-08-23) · **ADR**: [ADR-008](decisions/ADR-008-upgrade-path.md)
**Estado**: ESQUELETO — se completa al ejecutarlo.
**Corre sobre Cilium 1.19.6**, NO sobre 1.20.1.

> **Por qué este movimiento va primero ahora.** 4a se ejecutó el 23-ago y
> falló: Cilium 1.20.1 no *documenta* un Gateway API más nuevo, lo
> **requiere** — sin `referencegrants/v1`, `tlsroutes` ni
> `backendtlspolicies` su operador no arranca el controlador de Gateway API,
> y los Envoy que rotan después se quedan sin listeners, sin rutas y sin
> secreto TLS. 138 de 368 sondas del testigo se perdieron. El sentido seguro
> de este par es **CRDs nuevas bajo Cilium viejo**: el controlador de 1.19
> consume las versiones que conoce e ignora el resto. Detalle en ADR-008 §1
> e INCIDENTS #17 (8ª cara).

> Las CRDs las instalamos **nosotros** (`bootstrap/control-plane.yaml`, release
> oficial de kubernetes-sigs), no Cilium. El escalón se aplica con `kubectl
> apply` del `standard-install.yaml` de cada versión.

## LA VERIFICACIÓN QUE NO PUEDE FALTAR TRAS CADA ESCALÓN

`Gateway ... Programmed=True` **NO sirve como prueba**. Ese campo es una
caché del último controlador que lo tocó y sobrevive intacto a la muerte de
ese controlador — así es exactamente como 4a pasó todos sus checks mientras
la puerta estaba caída. Tras CADA escalón, en este orden:

```bash
# 1. El controlador está VIVO, no solo el campo. Esta es la línea que
#    delató el fallo de 4a, y aparece a los ~13s de arrancar el operador.
kubectl -n kube-system logs deploy/cilium-operator --tail=200 \
  | grep -iE "Required GatewayAPI resources|gateway-api"
#    → NO debe aparecer "Required GatewayAPI resources are not found"

# 2. El operador reconcilia de verdad: tocar algo y ver que responde
kubectl -n infra annotate gateway shared-gw witness/step="v1.X" --overwrite
kubectl -n infra get gateway shared-gw -o jsonpath='{.status.conditions[*].lastTransitionTime}'

# 3. Envoy tiene configuración: listener presente, sin fetch timeouts
kubectl -n kube-system logs ds/cilium-envoy --tail=50 \
  | grep -iE "add/update listener|initial fetch timed out"
#    → debe haber listener; NO debe haber timeouts nuevos

# 4. Y por encima de todo: el testigo sigue en enviadas == exitosas
bash scripts/witness-traffic.sh status
```

Un escalón sin las cuatro no está dado: se revierte esa CRD y se para.

## Por qué escalonado

Upstream: *"Although it is usually safe to upgrade across multiple Gateway
API minor versions at once, the safest and most widely tested path will
involve upgrading one minor version at a time."* Con un Gateway sirviendo
producción, se toma el camino probado: **v1.2 → v1.3 → v1.4 → v1.5 → v1.6**.

**Corrección respecto al brief**: el salto v1.2→v1.3 se marcó como sensible
por el cambio de forma de `Gateway.spec.infrastructure`. **Nosotros no
usamos ese campo** (verificado en el manifiesto; reverificar en vivo). El
escalonado se mantiene por prudencia general, no por ese riesgo concreto.

## Qué cambia en lo que SÍ usamos (v1.6.0)

- **HTTPRoute**: `retry.codes` debe ser único y `retry.attempts >= 1`;
  prohibidos filtros CORS repetidos del mismo tipo. Son **validaciones más
  estrictas**, no campos nuevos obligatorios.
- **HTTPRoute y GRPCRoute ya pueden compartir hostname** (antes se
  desaconsejaba). Nos afecta: servimos ambos por `*.logistics.lab`.
- TCPRoute/UDPRoute a GA y límites de TLSRoute: **no los usamos**.

## Ejecución, por escalón

```bash
bash scripts/witness-traffic.sh start "4b-gwapi-v1.X"
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.X.Y/standard-install.yaml
```

## Verificación tras CADA escalón (no solo al final)

1. `shared-gw`: `Accepted=True` y `Programmed=True`.
2. Las rutas de Repo 2: HTTPRoute y GRPCRoute con `Accepted` y `ResolvedRefs`.
3. `kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}'` — versión servida.
4. Si el Gateway materializara `spec.infrastructure`, comprobar que migró al esquema nuevo.
5. `bash scripts/witness-traffic.sh stop` → **`enviadas == exitosas`**.

## Rollback

De v1.3 en adelante los cambios son aditivos. El escalón con riesgo real es
el primero: **tener a mano el `standard-install.yaml` de v1.2.1** para
revertirlo.

## Tiempos (pendiente)

| Escalón | Tiempo | Veredicto del testigo |
|---|---|---|
| v1.2→v1.3 | — | — |
| v1.3→v1.4 | — | — |
| v1.4→v1.5 | — | — |
| v1.5→v1.6 | — | — |
