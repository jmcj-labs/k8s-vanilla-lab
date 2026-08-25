# RUNBOOK — 4b: Gateway API CRDs v1.2.1 → v1.6.1 (escalonado, canal híbrido)

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

## EL GATE DURO 6a/6b (obligatorio desde el escalón v1.5.1)

Desde v1.5.1 el bundle estándar sirve TLSRoute **solo en `v1`**, tirando el
`v1alpha2` que vigila Cilium 1.19.6. El overlay lo preserva — y estas dos
comprobaciones, deliberadamente redundantes, verifican que lo hizo:

```bash
# 6a — el ESQUEMA: v1alpha2 realmente SERVIDA.
#   NO usar jsonpath '[?(@.served)]': ese predicado filtra por que el CAMPO
#   EXISTA, no por su valor, y devuelve versiones con served=false (probado
#   sobre backendtlspolicies). Un gate que no distingue true de false no es
#   un gate. jq compara el valor.
SERVED=$(kubectl get crd tlsroutes.gateway.networking.k8s.io -o json \
  | jq -r '[.spec.versions[] | select(.served == true) | .name] | join(" ")')
[ -n "$SERVED" ] || { echo "✗ no pude LEER las versiones servidas"; exit 1; }
echo "$SERVED" | grep -qw v1alpha2 \
  || { echo "✗ v1alpha2 NO servida (sirve: $SERVED) → ROLLBACK"; exit 1; }

# 6b — el CONTROLADOR: lo que DECIDIÓ al leer ese esquema.
kubectl -n kube-system logs deploy/cilium-operator --tail=-1 \
  | grep -q "TLSRoute support is enabled" \
  || { echo "✗ el operador NO habilita TLSRoute → PARAR y ROLLBACK"; exit 1; }
```

6a mira el esquema; 6b mira lo que el controlador **hizo** con él. Son dos
preguntas distintas, y la 8ª cara de INCIDENTS #17 es precisamente el caso en
que el esquema estaba bien y el controlador no se había enterado.

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
producción, se toma el camino probado: ****v1.2.1 → v1.3.0 → v1.4.1 → v1.5.1 → v1.6.1**, con **canal híbrido**:
CRDs requeridos del canal `standard` **más el CRD experimental de TLSRoute
suelto** encima. Nunca el bundle experimental completo (arrastraría TCPRoute,
UDPRoute y ServiceImport que no usamos).

| escalón | qué se aplica |
|---|---|
| **v1.3.0** | `standard-install.yaml` + CRD experimental TLSRoute suelto (`v1alpha2`) |
| **v1.4.1** | `standard-install.yaml` (entra `BackendTLSPolicy/v1`) + TLSRoute experimental |
| **v1.5.1** | CRDs estándar requeridos **individuales, excluyendo TLSRoute** + TLSRoute experimental |
| **v1.6.1** | igual que v1.5.1 — final: TLSRoute sirviendo `v1` **y** `v1alpha2` |

Desde **v1.5.1** el bundle estándar incluye TLSRoute sirviendo **solo `v1`**,
y sobrescribiría el overlay: por eso a partir de ahí se aplican los CRDs
estándar individuales excluyendo TLSRoute (cilium/cilium#44920).

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

## Server-side apply SIN `--force-conflicts` por defecto

El apply client-side no sirve: estas CRDs exceden el límite de la anotación
`last-applied-configuration`. Pero `--force-conflicts` **no va por defecto**:
arrebata campos a su gestor actual sin decir a quién, y en un esquema que
sostiene la puerta de entrada eso es una transferencia de propiedad a ciegas.

**Siempre `diff` primero:**

```bash
kubectl diff --server-side --field-manager=gateway-api-crd-upgrade -f <manifiesto>
```

- **Sin conflicto** → `apply` con las mismas banderas. Para CRDs nuevas no
  debe haber conflicto en absoluto.
- **Con conflicto** → **PARAR**. Identificar campo y gestor:
  ```bash
  kubectl get crd <nombre> -o json | jq '.metadata.managedFields[] | {manager, operation, fields: .fieldsV1 | keys}'
  ```
  Decidir la transferencia **deliberadamente** y solo entonces usar
  `--force-conflicts` sobre el conjunto exacto de manifiestos cuyos campos y
  gestores se revisaron. No extender nunca el force al overlay ni a otro
  manifiesto por comodidad. La única excepción ejecutada fue el bundle standard
  de v1.3.0: el mismo conflicto de anotaciones y el mismo manager se verificó
  en sus cinco CRDs antes de autorizar el conjunto completo (evidencia abajo).

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

De v1.3 en adelante los cambios son aditivos, pero **quitar una versión de
`spec.versions` no basta**: el API server rechaza la CRD si esa versión sigue
listada en `status.storedVersions`. Lo descubrimos en v1.4.1, donde el
overlay movió la versión *storage* de TLSRoute de `v1alpha2` a `v1alpha3` y
`storedVersions` acumuló ambas.

La purga **no puede hacerse contra una versión que todavía no sea storage**:
el API server exige que `status.storedVersions` contenga la versión marcada
`storage:true`. El orden correcto, seguro solo con cero TLSRoutes, es:

| Rollback | storage destino | ¿Transición/purga? |
|---|---|---|
| v1.6.1 → v1.5.1 | `v1` | no; no se retira la storage actual |
| v1.5.1 → v1.4.1 | `v1alpha3` | sí: `v1` deja de existir en el destino |
| v1.4.1 → v1.3.0 | `v1alpha2` | sí: `v1alpha3` deja de existir |
| v1.3.0 → v1.2.1 | `v1alpha2` | no; storage no cambia |

Para los dos casos con transición, construir primero un CRD intermedio desde
el objeto vivo: conserva todas las versiones actuales y solo mueve
`storage:true` a la versión destino. Ejemplo parametrizado:

```bash
FROM=v1.5.1
TO=v1.4.1
TARGET_STORAGE=v1alpha3       # v1alpha2 para v1.4.1→v1.3.0
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# Control positivo: la purga solo es segura porque no hay objetos que migrar.
TLS_COUNT=$(kubectl get tlsroutes -A -o json | jq '.items | length')
[ "${TLS_COUNT}" -eq 0 ] || { echo "ABORTAR: hay ${TLS_COUNT} TLSRoutes; migrar objetos antes del rollback"; exit 1; }

kubectl get crd tlsroutes.gateway.networking.k8s.io -o json \
  | jq --arg target "${TARGET_STORAGE}" '
      del(.metadata.creationTimestamp, .metadata.generation,
          .metadata.managedFields, .metadata.resourceVersion,
          .metadata.uid, .status)
      | .spec.versions |= map(.storage = (.name == $target))' \
  > "${WORK}/tlsroute-storage-transition.json"

# DIFF primero, luego dry-run de servidor, y solo entonces mutación real.
bash scripts/crd-diff-gate.sh "${WORK}/tlsroute-storage-transition.json" \
  "TLSRoute storage ${FROM}→${TARGET_STORAGE}"
kubectl apply --server-side --field-manager=gateway-api-crd-upgrade \
  --dry-run=server -f "${WORK}/tlsroute-storage-transition.json" >/dev/null
kubectl apply --server-side --field-manager=gateway-api-crd-upgrade \
  -f "${WORK}/tlsroute-storage-transition.json"

# El API server debe haber incorporado la nueva storage a storedVersions.
kubectl get crd tlsroutes.gateway.networking.k8s.io -o json \
  | jq -e --arg target "${TARGET_STORAGE}" '
      ([.spec.versions[] | select(.storage == true) | .name] == [$target]) and
      (.status.storedVersions | index($target) != null)' >/dev/null \
  || { echo "ABORTAR: la transición de storage no quedó acreditada"; exit 1; }

# Con cero objetos y la storage destino ya activa, retirar versiones antiguas.
kubectl patch crd tlsroutes.gateway.networking.k8s.io --subresource=status \
  --type=merge -p "{\"status\":{\"storedVersions\":[\"${TARGET_STORAGE}\"]}}"

TARGET_TLS="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${TO}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml"
bash scripts/crd-diff-gate.sh "${TARGET_TLS}" "TLSRoute rollback ${FROM}→${TO}"
kubectl apply --server-side --field-manager=gateway-api-crd-upgrade \
  --dry-run=server -f "${TARGET_TLS}" >/dev/null
kubectl apply --server-side --field-manager=gateway-api-crd-upgrade -f "${TARGET_TLS}"
```

Los manifiestos standard del escalón destino pasan por la misma pareja
`crd-diff-gate.sh` + `kubectl apply --dry-run=server` **antes** de cualquier
apply real. Si cualquier diff devuelve conflicto o error, se para: un
rollback urgente no recibe permiso para saltarse el gate.

El escalón con más riesgo sigue siendo el primero: **tener a mano el
`standard-install.yaml` de v1.2.1**.

## DEUDA — el bootstrap pinea v1.2.1, así que 4b es un ESTADO, no un hito

`bootstrap/control-plane.yaml` instala **Gateway API v1.2.1**. La escalera de
4b se ejecutó **in situ sobre un cluster vivo**, y ese estado murió con el
`tofu destroy`. Lo que quedó en el repo son runbooks y evidencia — **no un
bootstrap que reproduzca el resultado**.

**Consecuencia operativa**: cada encarnación nueva del cluster nace en v1.2.1
y **necesita reejecutar esta escalera antes de 4a**. Descubierto el 25-ago al
ir a arrancar 4a-v3 sobre un cluster fresco: la premisa "el cluster nace en
v1.6.1" era falsa, y el gate de entrada de 4a habría fallado exactamente como
el 23-ago.

**Candidato de arreglo**: pinear **v1.6.1 por el canal híbrido** (los CRDs
estándar requeridos + el overlay experimental de TLSRoute) en el bootstrap,
para que el cluster nazca ya en el estado que 4a exige. **PR propio con su
propia validación** — cambia el camino probado, porque 4b se validó *subiendo
escalón a escalón* desde v1.2.1, no naciendo en v1.6.1. Post-S2, o cuando
moleste lo suficiente.

## EJECUTADO — 2026-08-24, escalera completa

| Escalón | Applies | Gate 6a/6b | Canary | Testigo acumulado |
|---|---|---|---|---|
| **v1.2.1 → v1.3.0** | bundle standard (`--force-conflicts`, transición client-side→server-side) + overlay TLSRoute `v1alpha2` | n/a (aún sin riesgo TLSRoute) · `TLSRoute support is enabled` aparece por primera vez | ✓ obs 1→2 | 1174/1174 |
| **v1.3.0 → v1.4.1** | bundle standard + overlay · **sin force** | ✓ · 0 errores fatales | ✓ obs 1→2 | 1429/1429 |
| **v1.4.1 → v1.5.1** | **6 CRDs individuales** (TLSRoute excluido) + overlay · sin force | ✓ **6a/6b** — el escalón que justifica la ruta híbrida | ✓ `Accepted=True` obs 1→2 | 2328/2328 |
| **v1.5.1 → v1.6.1** | 6 individuales + overlay · sin force | ✓ **6a/6b** + **gate 7 SCHEMA READY FOR 4a** | ✓ `Accepted=True` obs 1→2 | **2726/2726** |

### Incidencia real del primer escalón: conflicto y transferencia autorizada

La fila v1.2.1→v1.3.0 **no fue limpia**. El diff se ejecutó primero sin force
y terminó `rc=2` con `Error from server (Conflict)` sobre
`gateway.networking.k8s.io/bundle-version`; se detuvo el escalón. Como
`managedFields` no se muestra por defecto, se inspeccionó con
`kubectl get crd ... -o yaml --show-managed-fields`: el propietario era
`kubectl-client-side-apply`, rastro del bootstrap client-side, y sostenía las
cuatro anotaciones afectadas en los cinco CRDs del bundle standard.

La transferencia concreta de esas anotaciones a
`gateway-api-crd-upgrade` se presentó a dirección y fue autorizada **antes**
de ejecutar nada. Solo entonces se repitió el apply con
`--force-conflicts`, limitado al bundle standard revisado; el overlay
TLSRoute entró sin force. Era una transferencia necesaria: la anotación de
bundle debía pasar de v1.2.1 a v1.3.0 y no existía un segundo actor
contendiendo el campo. El efecto conocido queda aceptado y visible:
`kubectl.kubernetes.io/last-applied-configuration` queda huérfana, ya no la
mantiene ningún apply client-side y no se eliminó. En los tres escalones
posteriores no hubo force porque los campos ya pertenecían al manager nuevo.

**Veredicto del testigo, ventana única sobre los cuatro escalones**:

```
=== WITNESS WINDOW '4b-gwapi-crds' ===
  from     : 2026-08-24T12:30:05Z
  sent     : 2726
  successful: 2726
  max gap  : 3s between consecutive probes
✓ VERDICT: sent == successful (2726/2726) — the entry path never broke
```

El `max gap` de 3 s importa tanto como el recuento: sin él, un 2726/2726 sobre
una serie con agujeros no probaría nada del intervalo no observado.

**Estado final** (`bundle=v1.6.1` en los siete):

| CRD | stored | served |
|---|---|---|
| tlsroutes | v1alpha2, v1alpha3, v1 | **v1, v1alpha2, v1alpha3** |
| referencegrants | v1beta1 | **v1**, v1beta1 |
| backendtlspolicies | v1 | **v1** |
| gatewayclasses / gateways / httproutes | v1 | v1, v1beta1 |
| grpcroutes | v1 | v1 |

## Tiempos (pendiente)

| Escalón | Tiempo | Veredicto del testigo |
|---|---|---|
| v1.2→v1.3 | — | — |
| v1.3→v1.4 | — | — |
| v1.4→v1.5 | — | — |
| v1.5→v1.6 | — | — |
