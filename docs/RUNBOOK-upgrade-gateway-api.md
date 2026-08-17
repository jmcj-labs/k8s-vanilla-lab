# RUNBOOK — 4b: Gateway API CRDs v1.2.1 → v1.6.x (escalonado)

**Pieza**: S2-4, segundo movimiento · **ADR**: [ADR-008](decisions/ADR-008-upgrade-path.md)
**Estado**: ESQUELETO — se completa al ejecutarlo.

> Las CRDs las instalamos **nosotros** (`bootstrap/control-plane.yaml`, release
> oficial de kubernetes-sigs), no Cilium. El escalón se aplica con `kubectl
> apply` del `standard-install.yaml` de cada versión.

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
