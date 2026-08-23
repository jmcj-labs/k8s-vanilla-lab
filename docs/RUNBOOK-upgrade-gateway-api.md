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

## ORDEN DE LA VENTANA: el testigo se abre ANTES del primer `kubectl apply`

El hueco potencial empieza con **el primer cambio de esquema**, no después de
él. Un testigo abierto tras aplicar la primera CRD no puede afirmar nada
sobre el intervalo en que esa CRD entró.

```bash
bash scripts/witness-traffic.sh start "4b-gwapi-crds"
bash scripts/witness-traffic.sh status   # enviadas subiendo, latido reciente
# ↑ y SOLO ENTONCES el primer kubectl apply de la escalera
```

## PRE-ESCALÓN v1.2 → v1.3: `spec.infrastructure` contra el Gateway VIVO

El brief marcó ese salto como sensible por el cambio de forma de ese campo, y
la auditoría dijo que no lo usamos — **pero eso se comprobó en el
manifiesto**. El controlador puede haberlo materializado en runtime con
defaults. Antes de subir la CRD, preguntarle al objeto vivo:

```bash
kubectl get gateway shared-gw -n infra -o jsonpath='{.spec.infrastructure}'
#   → vacío  = confirmado, el salto no nos afecta por ese motivo
#   → algo   = PARAR. El campo existe en runtime y cambia de forma: revisar
#              su equivalencia en v1.3 antes de tocar nada.
```

Verificar el manifiesto y verificar el objeto vivo no son la misma pregunta.

## LA VERIFICACIÓN TRAS CADA ESCALÓN: probar que el controlador TRABAJA

**No** `Programmed=True`. **No** "no aparece el error de CRD en el log". Las
dos son la 8ª cara de INCIDENTS #17 aplicada a su propia verificación:

- `Programmed=True` es **la caché del último controlador que se ocupó**. Es
  literalmente el campo que en 4a decía que todo iba bien con la puerta
  cerrada. Sobrevive intacto a la muerte de su controlador.
- Grepear el log buscando la **ausencia** de un error conocido no es prueba
  de trabajo: un controlador que no arranca, que arranca y muere, que pierde
  la elección de líder o que se queda colgado tampoco escribe *ese* error.

La prueba es **positiva y activa**: hacerle reconciliar algo que no existía.

```bash
bash scripts/verify-gateway-controller.sh v1.3     # el escalón que acabas de dar
```

Crea una HTTPRoute canary efímera, exige que el controlador **escriba status
nombrándose a sí mismo** con `observedGeneration == generation`, luego
**cambia** la ruta y exige que `observedGeneration` **siga** a la nueva
`generation` — y la borra pase lo que pase. Ese segundo paso es el que separa
*"algo reconcilió esto una vez"* de *"algo está reconciliando ahora"*: un
status rancio no puede seguir una generación que nunca ha visto. Un timeout
es **fallo**, no pase.

Y por encima de todo, tras cada escalón:

```bash
bash scripts/witness-traffic.sh status   # enviadas == exitosas, latido vivo
```

Un escalón sin las tres —canary reconciliado, `spec.infrastructure` cuando
toque, testigo intacto— no está dado: se revierte esa CRD y se para.

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

El testigo se abrió **una vez, antes del primer escalón** (§ORDEN DE LA
VENTANA) y sigue abierto durante toda la escalera: no se cierra entre
escalones, porque el hueco puede caer justo en la transición.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.X.Y/standard-install.yaml
```

## Verificación tras CADA escalón (no solo al final)

La prueba de que el controlador trabaja está en §LA VERIFICACIÓN TRAS CADA
ESCALÓN y es la que manda. Estas son complementarias, y **ninguna la
sustituye**:

1. **`bash scripts/verify-gateway-controller.sh v1.X`** — el canary activo.
   Si falla, se para aquí; lo demás de esta lista es ruido si el controlador
   no está reconciliando.
2. Rutas de Repo 2: HTTPRoute y GRPCRoute con `Accepted` y `ResolvedRefs`
   — **y con `observedGeneration` al día**, no solo la condición.
3. `kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}'`
   — versión servida, para confirmar que el escalón entró de verdad.
4. Si el Gateway materializara `spec.infrastructure`, comprobar la migración
   al esquema nuevo (ver §PRE-ESCALÓN v1.2 → v1.3).
5. `bash scripts/witness-traffic.sh status` → **`enviadas == exitosas`** y
   latido vivo. El `stop` va **al terminar la escalera**, no por escalón.

> `shared-gw` con `Accepted/Programmed=True` **NO está en esta lista a
> propósito**. Es el campo que mintió en 4a; leerlo aquí reintroduciría el
> fallo que este runbook existe para evitar. Si quieres mirarlo, míralo
> **después** del canary y como información, nunca como criterio.

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
