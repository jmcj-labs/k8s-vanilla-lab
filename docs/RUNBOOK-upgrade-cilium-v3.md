# RUNBOOK — 4a-v3: Cilium 1.19.6 → 1.20.1 por DRENAJE COORDINADO

**Pieza**: S2-4, segundo movimiento, **tercer intento** · **ADR**: [ADR-008](decisions/ADR-008-upgrade-path.md)
**Estado**: PREPARADO, NO EJECUTADO.
**Punto de partida**: Cilium 1.19.6 · CRDs Gateway API v1.6.1 · gate
`SCHEMA READY FOR 4a` verde · 4b coronado 2726/2726.

> **El cambio de estrategia.** v1 y v2 buscaban que el balanceador **detectara**
> el nodo caído. Esto es imposible de hacer bien en esta topología: el HC del
> NLB en TCP es ciego a Envoy, y el HTTPS nativo no permite enviar el SNI/Host
> que exige el listener del Gateway. Así que dejamos de depender de la
> detección y pasamos al
> **drenaje proactivo**: se saca el nodo del pool ANTES de tocarlo y se
> devuelve DESPUÉS de comprobar que sirve. El balanceador no tiene que
> adivinar nada.
>
> Consecuencia directa: **`maxUnavailable` deja de importar** — pasamos a
> `OnDelete` y el rollout lo conducimos nosotros, pod a pod.

## 0. Reversión del agregador de readiness (#73)

**No se usa.** El HC del NLB se queda en **TCP/30443 tal cual está**: sigue
sirviendo para el caso "nodo muerto del todo" en régimen estable, y no lo
tocamos.

**Lo que hay que deshacer es sorprendentemente poco, y conviene decirlo en vez
de aparentar una reversión grande**: el agregador **nunca llegó a
desplegarse**. `platform/install.sh` no lo referencia, `tofu/` no contiene
ninguna regla del 9890 y no existe ningún recurso de infra asociado.
Verificado, no supuesto.

- **Se borra**: `platform/node-readiness/daemonset.yaml` — el único artefacto
  de despliegue.
- **Se queda como referencia**: el binario Go, sus tests y el Dockerfile, con
  una nota en cabecera de que NO forma parte del despliegue. Su valor no es el
  código: es la **investigación** que probó, desde el fuente de Cilium, que
  `/healthz` no cubre la programación del NodePort (INCIDENTS #20).
- **Nada que revertir** en `tofu/`, en el SG de workers ni en el target group.

## 0.a Inicialización — TODO lo que las fases consumen, antes de usarlo

Prueba del operador virgen: el runbook debe correr **de arriba abajo** sin
saltar hacia delante ni depender de residuos de intentos anteriores. Lo que
antes vivía en §5 —y las fases ya consumían— se crea aquí.

```bash
set -euo pipefail
export REPO_ROOT=$(git rev-parse --show-toplevel)
export CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
export AWS_REGION="${AWS_REGION:-eu-west-1}"
export WITNESS_STATE_DIR="/tmp/witness-${CLUSTER_NAME}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/${CLUSTER_NAME}.conf}"

# Directorio limpio: un residuo de un intento previo se leería como evidencia
# de este. Si existe, se archiva en vez de mezclarse.
[ -d /tmp/4a-v3 ] && mv /tmp/4a-v3 "/tmp/4a-v3.prev.$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p /tmp/4a-v3
: > /tmp/4a-v3/instrumentation.pids     # registro ÚNICO de toda la instrumentación

command -v grpcurl >/dev/null 2>&1 || {
  echo "✗ grpcurl es obligatorio en 4a: sin él no existe testigo gRPC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq es obligatorio"; exit 1; }

# Helper usado por §2.5b y §3.4b: abre captura sobre los pods NUEVOS de un nodo.
capture_new_pods() {
  local NODE="$1"
  for APP in cilium cilium-envoy; do
    local POD
    POD=$(kubectl -n kube-system get pods -l k8s-app=$APP \
          --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')
    [ -n "$POD" ] || { echo "✗ no encuentro el pod $APP nuevo en $NODE → PARAR"; exit 1; }
    kubectl -n kube-system logs "$POD" -f --timestamps \
      > "/tmp/4a-v3/${APP}-${NODE}-POST.log" 2>&1 &
    echo "$!" >> /tmp/4a-v3/instrumentation.pids
    echo "  captura abierta sobre $POD → ${APP}-${NODE}-POST.log"
  done
}
```

## 0.b Pre-flight — y es quien CREA `/tmp/cilium-live-values.yaml`

Sin este paso las dos fases de helm corren con un `-f` que no existe. Es el
mismo script que pasó en los dos intentos anteriores: captura los values
**vivos**, valida los críticos, rechaza un `k8sServiceHost` que sea IP
(ADR-007) y exige el DaemonSet de pre-flight listo en los 6 nodos, con el
timeout como fallo.

```bash
bash scripts/preflight-cilium-upgrade.sh 1.20.1
[ -s /tmp/cilium-live-values.yaml ] || { echo "✗ el pre-flight no dejó values → PARAR"; exit 1; }
bash scripts/verify-cilium-120-schema.sh || { echo "✗ el esquema no cumple 1.20.1 → PARAR"; exit 1; }
```

## 1. Paso previo: `OnDelete` confirmado ANTES de tocar versiones

El riesgo que esto evita: si el mismo `helm upgrade` introdujera `OnDelete`
**y** la imagen nueva, la transición sería una carrera — y apostar a que el
controlador lea la estrategia nueva antes de rodar es exactamente la clase de
suposición que llevamos dos intentos pagando.

**Dos fases de helm, y la primera NO cambia versiones:**

```bash
# 1.0 SNAPSHOT DE REFERENCIA — el conjunto exacto nodo/UID/startTime/imagen de
#     AMBOS DaemonSets. Sin esto, "no rodó nada" es una impresión; con esto es
#     una igualdad que un comando puede negar.
snapshot_pods() {
  kubectl -n kube-system get pods -l 'k8s-app in (cilium,cilium-envoy)' \
    -o jsonpath='{range .items[*]}{.spec.nodeName}|{.metadata.labels.k8s-app}|{.metadata.uid}|{.status.startTime}|{.spec.containers[0].image}{"\n"}{end}' \
    | sort
}
snapshot_pods > /tmp/4a-v3/pods-before.txt
N=$(wc -l < /tmp/4a-v3/pods-before.txt | tr -d ' ')
echo "  control: esperaba 12 pods (6 agentes + 6 envoy), capturé $N"
[ "$N" -eq 12 ] || { echo "✗ el snapshot no cubre los 12 pods → NO CONTINUAR"; exit 1; }

# Reutilizable tras CADA helm: igualdad estricta contra el snapshot.
assert_nothing_rolled() {
  snapshot_pods > /tmp/4a-v3/pods-after-$1.txt
  if diff -u /tmp/4a-v3/pods-before.txt /tmp/4a-v3/pods-after-$1.txt; then
    echo "  ✓ $1: mismos UID y startTime en los 12 pods — NADA rodó"
  else
    echo "✗ $1: el conjunto de pods CAMBIÓ. helm rodó por su cuenta → PARAR"
    exit 1
  fi
}

# FASE 1 — misma versión 1.19.6, solo la estrategia. Nada debe rodar.
helm upgrade cilium cilium/cilium --version 1.19.6 \
  --namespace kube-system -f /tmp/cilium-live-values.yaml \
  --set updateStrategy.type=OnDelete \
  --set updateStrategy.rollingUpdate=null \
  --set envoy.updateStrategy.type=OnDelete \
  --set envoy.updateStrategy.rollingUpdate=null \
  --wait --timeout 5m

# VERIFICACIÓN DURA, con aserción de control (INCIDENTS #19)
for D in cilium cilium-envoy; do
  T=$(kubectl -n kube-system get ds "$D" -o jsonpath='{.spec.updateStrategy.type}')
  R=$(kubectl -n kube-system get ds "$D" -o jsonpath='{.spec.updateStrategy.rollingUpdate}')
  echo "  $D → $T"
  [ "$T" = "OnDelete" ] || { echo "✗ $D NO está en OnDelete → NO CONTINUAR"; exit 1; }
  [ -z "$R" ] || { echo "✗ $D conserva rollingUpdate bajo OnDelete → NO CONTINUAR"; exit 1; }
done

# Y que la fase 1 no rodó nada — EJECUTABLE, no una lectura a ojo
assert_nothing_rolled fase1
```

**Solo con `OnDelete` confirmado en ambos** se pasa a la fase 2.

```bash
# FASE 2 — la versión. Con OnDelete, NINGÚN pod rueda por sí solo.
helm upgrade cilium cilium/cilium --version 1.20.1 \
  --namespace kube-system -f /tmp/cilium-live-values.yaml \
  --set updateStrategy.type=OnDelete \
  --set updateStrategy.rollingUpdate=null \
  --set envoy.updateStrategy.type=OnDelete \
  --set envoy.updateStrategy.rollingUpdate=null \
  --set upgradeCompatibility=1.19 \
  --wait --timeout 10m

# 1.2 LA GARANTÍA DE QUE MANDA EL DRENAJE Y NO HELM: plantilla NUEVA, pods
#     VIEJOS. Las dos mitades son aserciones; ninguna es prosa.
assert_nothing_rolled fase2          # los 12 pods siguen siendo los mismos

for D in cilium:1.20.1 cilium-envoy:v1.37; do
  DS=${D%%:*}; WANT=${D##*:}
  TPL=$(kubectl -n kube-system get ds "$DS" -o jsonpath='{.spec.template.spec.containers[0].image}')
  echo "  plantilla $DS → $TPL (esperaba contener $WANT)"
  case "$TPL" in *"$WANT"*) : ;; *) echo "✗ la plantilla de $DS NO es la nueva → PARAR"; exit 1 ;; esac
done

RUNNING_NEW=$(kubectl -n kube-system get pods -l 'k8s-app in (cilium,cilium-envoy)' \
  -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' \
  | grep -cE '1\.20\.1|v1\.37' || true)
echo "  control: esperaba 0 pods ya en la versión nueva, encontré $RUNNING_NEW"
[ "$RUNNING_NEW" -eq 0 ] || { echo "✗ algún pod YA rodó: OnDelete no está conteniendo → PARAR"; exit 1; }
echo "  ✓ plantilla nueva + pods viejos: el orden lo controla el drenaje"
```

> **`upgradeCompatibility=1.19`** es un hallazgo del post-mortem del 24-ago que
> NO estaba en los intentos anteriores. Cilium lo documenta literalmente:
> *"To minimize datapath disruption during the upgrade, the
> `upgradeCompatibility` option should be set to the initial Cilium version
> which was installed in this cluster."* No lo pusimos, y medimos interrupción
> del datapath. No es prueba de causalidad, pero es negligente omitirlo otra vez.

**Tras la fase 2, comprobar que efectivamente NO rodó nada**: los DaemonSets
mostrarán la imagen nueva en `.spec.template` y los pods **seguirán con la
vieja**. Eso es lo correcto y es la señal de que `OnDelete` funciona.

## 2. Drenaje por worker — los 3, de uno en uno

`deregistration_delay = 10s` en ambos target groups (verificado en
`tofu/modules/nlb/main.tf`). Margen de trabajo: **30 s**.

Para cada worker `W` (instance-id `I`), en orden y **sin solapar**:

```bash
TG=$(aws elbv2 describe-target-groups --region eu-west-1 \
  --query "TargetGroups[?Port==\`30443\`].TargetGroupArn" --output text)

# 2.1 SACAR del pool
aws elbv2 deregister-targets --region eu-west-1 --target-group-arn "$TG" --targets Id=$I

# 2.2 ESPERAR la transición de AWS 'draining' → 'unused'; no inferirla de un
#     sleep. Es el gate de baja del target configurado para esta ceremonia,
#     con timeout, y el timeout es FALLO.
for i in $(seq 1 20); do
  S=$(aws elbv2 describe-target-health --region eu-west-1 --target-group-arn "$TG" \
      --targets Id=$I --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)
  echo "  $I → $S"
  [ "$S" = "unused" ] && break
  sleep 5
done
[ "$S" = "unused" ] || { echo "✗ $I no terminó de drenar → PARAR"; exit 1; }

# 2.3 ASERCIÓN DE CONTROL: los otros dos SIGUEN healthy
H=$(aws elbv2 describe-target-health --region eu-west-1 --target-group-arn "$TG" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
echo "  esperaba 2 healthy tras drenar uno, encontré $H"
[ "$H" -eq 2 ] || { echo "✗ el pool no tiene 2 sanos → PARAR, NO tocar este nodo"; exit 1; }

# 2.4 RODAR los dos pods de ESE nodo, y solo de ese
kubectl -n kube-system delete pod -l k8s-app=cilium       --field-selector spec.nodeName=$W
kubectl -n kube-system delete pod -l k8s-app=cilium-envoy --field-selector spec.nodeName=$W

# 2.5 ESPERAR a que ambos vuelvan Ready EN ESE NODO, con la imagen nueva
kubectl -n kube-system wait --for=condition=Ready pod \
  -l k8s-app=cilium --field-selector spec.nodeName=$W --timeout=180s
kubectl -n kube-system wait --for=condition=Ready pod \
  -l k8s-app=cilium-envoy --field-selector spec.nodeName=$W --timeout=180s
kubectl -n kube-system get pods --field-selector spec.nodeName=$W \
  -l 'k8s-app in (cilium,cilium-envoy)' \
  -o custom-columns='POD:.metadata.name,IMG:.spec.containers[0].image'
#   → cilium v1.20.1 y cilium-envoy v1.37.x

# 2.5b CAPTURA SOBRE LOS PODS NUEVOS DE ESTE NODO. El seguimiento agregado
#      de §0.c no los alcanza (se enganchó a los viejos), así que el de los
#      1.20.1 se abre aquí, por nodo, en cuanto nacen.
capture_new_pods "$W"
# 2.6 DEVOLVER al pool y esperar healthy. La prueba decisiva ocurre DESPUÉS:
#     debe incluir al nodo dentro del camino real del NLB, no un hairpin.
aws elbv2 register-targets --region eu-west-1 --target-group-arn "$TG" \
  --targets Id=$I,Port=30443
aws elbv2 wait target-in-service --region eu-west-1 --target-group-arn "$TG" --targets Id=$I

# 2.7 ASERCIÓN DE CAPACIDAD: los 3 healthy otra vez
H=$(aws elbv2 describe-target-health --region eu-west-1 --target-group-arn "$TG" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
echo "  esperaba 3 healthy, encontré $H"
[ "$H" -eq 3 ] || { echo "✗ PARAR"; exit 1; }

# 2.8 PROBATION SOSTENIDA YA REINTEGRADO — 30 ciclos durante >=60 s,
#     cubriendo dos intervalos nominales de 30 s del HC además del waiter.
#     Cada `once` exige HTTP Y gRPC OK por la puerta pública. Son conexiones
#     nuevas contra el sistema con el nodo otra vez elegible en el NLB: no es
#     una prueba hairpin ni una única petición afortunada.
PROBE_N=30
PROBE_SLEEP=2
PROBE_STARTED=$(date +%s)
for n in $(seq 1 "$PROBE_N"); do
  echo "  probation $n/$PROBE_N para $W"
  bash "$REPO_ROOT/scripts/witness-traffic.sh" once || {
    echo "✗ probation falló con $W reintegrado → PAUSAR; no tocar el siguiente nodo"
    exit 1
  }
  sleep "$PROBE_SLEEP"
done
PROBE_ELAPSED=$(( $(date +%s) - PROBE_STARTED ))
echo "  control: esperaba 30 ciclos en >=60 s; ejecuté $PROBE_N en ${PROBE_ELAPSED}s"
[ "$PROBE_N" -eq 30 ] && [ "$PROBE_ELAPSED" -ge 60 ] || {
  echo "✗ la probation no cubrió su presupuesto mínimo → PAUSAR"; exit 1;
}

# 2.9 SEGUNDA RED: el testigo continuo tampoco puede haber visto UN fallo.
#     `status` es informativo; la igualdad siguiente es el gate fail-closed.
bash "$REPO_ROOT/scripts/witness-traffic.sh" status
SERIES="${WITNESS_STATE_DIR}/series"
[ -s "$SERIES" ] || { echo "✗ serie del testigo ausente/vacía → PAUSAR"; exit 1; }
SENT=$(awk '$3!="event"{n++} END{print n+0}' "$SERIES")
SUCCESSFUL=$(awk '$3!="event" && $4=="ok"{n++} END{print n+0}' "$SERIES")
echo "  control testigo: sent=$SENT successful=$SUCCESSFUL"
[ "$SENT" -gt 0 ] && [ "$SENT" -eq "$SUCCESSFUL" ] || {
  echo "✗ el testigo registró pérdida → PAUSAR; no tocar el siguiente nodo"; exit 1;
}
```

**Cada nodo se reintegra y supera probation ANTES de drenar el siguiente.** Así
el pool alterna 3→2→3 y nunca baja de dos targets sirviendo. Rodar los tres y
devolverlos al final degradaría el pool a 2→1→0; queda prohibido.

La mezcla transitoria —por ejemplo, un worker 1.20.1 y dos 1.19.6— es la
forma normal de un upgrade consecutivo y dura solo hasta el siguiente nodo.
Los datapaths y Envoy son locales a cada nodo; no comparten estado de conexión
que tenga que migrar entre versiones, y HTTP/gRPC no tienen afinidad a una
versión de Cilium. El plano común sigue siendo Kubernetes con las mismas CRDs
v1.6.1, y `upgradeCompatibility=1.19` mantiene compatibles los defaults durante
la convivencia. Es el modelo que describe la
[guía oficial de upgrade de Cilium](https://docs.cilium.io/en/stable/operations/upgrade/):
convergencia progresiva de todos los componentes, no sustitución simultánea.
El estado final, y solo el final, exige seis nodos en 1.20.1.

**Un solo fallo ya invalida cero-pérdida y pausa el rollout.** La racha **≥10**
se conserva únicamente como clasificador forense del patrón (23-ago → 128,
24-ago → 35, 4b → 0), nunca como permiso para continuar tras 1–9 pérdidas.

## 3. Los control planes — plano separado

**Cinturón sobre tirantes.** `kubeadm` genera `kube-apiserver` como pod estático
y lo enlaza a la dirección anunciada del nodo en `:6443`; Cilium documenta que
un pod `hostNetwork` usa directamente la IP del host y no es un pod cuya red
configure el CNI. El target del NLB es precisamente `IP-del-CP:6443`: no es un
Service ni atraviesa la traducción NodePort/KPR que falló en los workers. Por
eso el reinicio del agente **no debería** tirar ese API server. Fuentes:
[fase kubeadm del API server](https://kubernetes.io/docs/reference/setup-tools/kubeadm/generated/kubeadm_init/kubeadm_init_phase_control-plane_apiserver/)
y [pods hostNetwork en Cilium](https://docs.cilium.io/en/stable/operations/troubleshooting/#ensure-the-pod-is-managed-by-cilium).

No convertimos ese "debería" en una suposición operacional: el CP se saca del
TG del API, se espera `unused` y se añade **30 s completos** antes de tocar su
agente. Son 90 s de margen total para los tres CPs, a cambio de no exponer el
endpoint a una premisa no ejercitada.

**Por qué uno a uno es seguro**: etcd tiene 3 miembros y **tolera perder uno**
manteniendo quórum; los otros 2 CPs siguen sirviendo el API. Es el mismo
supuesto que la pieza 3 ya validó con el drill de pérdida de CP.

Para cada CP `C` (instance-id `J`), en orden y sin solapar:

```bash
TGAPI=$(aws elbv2 describe-target-groups --region eu-west-1 \
  --query "TargetGroups[?Port==\`6443\`].TargetGroupArn" --output text)

# 3.1 Quórum ANTES de tocar nada — si ya está degradado, no se sigue
kubectl -n kube-system exec ds/cilium -- true 2>/dev/null   # API respondiendo
ETCD=$(kubectl -n kube-system get pods -l component=etcd --no-headers | grep -c "1/1 *Running")
echo "  esperaba 3 etcd Running, encontré $ETCD"
[ "$ETCD" -eq 3 ] || { echo "✗ quórum no íntegro → NO tocar CPs"; exit 1; }

# 3.2 Drenar ESE CP del target group del API
aws elbv2 deregister-targets --region eu-west-1 --target-group-arn "$TGAPI" --targets Id=$J
for i in $(seq 1 20); do
  S=$(aws elbv2 describe-target-health --region eu-west-1 --target-group-arn "$TGAPI" \
      --targets Id=$J --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)
  echo "  $J → $S"
  [ "$S" = "unused" ] && break
  sleep 5
done
[ "$S" = "unused" ] || { echo "✗ $J no terminó de drenar → PARAR"; exit 1; }
echo "  margen CP: 30 s fuera del pool antes de tocar el agente"
sleep 30

# 3.3 Aserción: quedan 2 CPs healthy sirviendo el API
HA=$(aws elbv2 describe-target-health --region eu-west-1 --target-group-arn "$TGAPI" \
     --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
echo "  esperaba 2 CPs healthy, encontré $HA"
[ "$HA" -eq 2 ] || { echo "✗ PARAR"; exit 1; }

# 3.4 Rodar SOLO el agente de ese CP (los CPs también corren cilium-envoy;
#     rodarlo es inocuo porque ningún CP está en el TG del Gateway, pero se
#     hace en la misma ventana para no dejar el cluster en versiones mixtas)
kubectl -n kube-system delete pod -l k8s-app=cilium       --field-selector spec.nodeName=$C
kubectl -n kube-system delete pod -l k8s-app=cilium-envoy --field-selector spec.nodeName=$C
kubectl -n kube-system wait --for=condition=Ready pod \
  -l k8s-app=cilium --field-selector spec.nodeName=$C --timeout=180s

# 3.5 AMBOS pods de ese CP Ready y en la versión nueva
for APP in cilium cilium-envoy; do
  kubectl -n kube-system wait --for=condition=Ready pod \
    -l k8s-app=$APP --field-selector spec.nodeName=$C --timeout=180s \
    || { echo "✗ $APP no volvió Ready en $C → NO re-registrar, ir a §4"; exit 1; }
done
READY_CP=$(kubectl -n kube-system get pods --field-selector spec.nodeName=$C \
  -l 'k8s-app in (cilium,cilium-envoy)' \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true)
echo "  control: esperaba 2 pods Ready en $C, encontré $READY_CP"
[ "$READY_CP" -eq 2 ] || { echo "✗ PARAR"; exit 1; }

# 3.5b CAPTURA SOBRE LOS PODS NUEVOS DE ESTE CP — obligatorio, no residual.
#      Cubrir 6 de 12 pods nuevos deja ciega la mitad más crítica: si 4a-v3
#      falla en un control plane, necesitamos sus logs EN VIVO igual que los
#      perdimos con el Envoy 1.37.5 el 24-ago.
capture_new_pods "$C"

# 3.6 EL API DE ESE CP RESPONDE DE VERDAD — autenticado, no solo TLS.
#     401/403 acreditan que hay TLS y un servidor, NO que el API sirva: son
#     rechazos. Se exige 200 con el token del propio kubeconfig.
CP_IP=$(kubectl get node $C -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
CODE=$(kubectl get --raw='/readyz' --server="https://${CP_IP}:6443" \
         --insecure-skip-tls-verify=true 2>/dev/null | tr -d '\n')
echo "  /readyz autenticado en $CP_IP → '${CODE}'"
[ "$CODE" = "ok" ] || { echo "✗ ese CP NO sirve el API (esperaba 'ok') → NO re-registrar, ir a §4"; exit 1; }

# 3.7 ETCD SANO COMO COMANDO, no como comentario
ETCD_OK=$(kubectl -n kube-system exec ds/cilium -- true 2>/dev/null; \
  kubectl -n kube-system get pods -l component=etcd \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true)
echo "  control: esperaba 3 etcd Ready, encontré $ETCD_OK"
[ "$ETCD_OK" -eq 3 ] || { echo "✗ quórum degradado → PARAR"; exit 1; }

# 3.8 Devolver al pool y exigir los TRES targets del API healthy
aws elbv2 register-targets --region eu-west-1 --target-group-arn "$TGAPI" --targets Id=$J,Port=6443
aws elbv2 wait target-in-service --region eu-west-1 --target-group-arn "$TGAPI" --targets Id=$J
HA=$(aws elbv2 describe-target-health --region eu-west-1 --target-group-arn "$TGAPI" \
     --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
echo "  control: esperaba 3 CPs healthy antes del siguiente, encontré $HA"
[ "$HA" -eq 3 ] || { echo "✗ PARAR, no tocar el siguiente CP"; exit 1; }
```

> **Orden entre planos**: primero los **workers** (donde vive el tráfico que el
> testigo mide) y después los **CPs**. Si algo se tuerce con los workers, se
> aborta con el plano de control intacto y todas las herramientas funcionando.

## 4. Rollback

**Regla: un nodo que no vuelve a servir SE QUEDA DRENADO y se para.** No se
re-registra, no se pasa al siguiente.

Razones, por orden de importancia:

1. **Con 2/3 workers sirviendo, la puerta sigue abierta.** El testigo debería
   seguir en verde. Hay tiempo para pensar.
2. **Conserva la evidencia.** El 24-ago el `helm rollback` recreó los pods y se
   llevó los logs de Envoy 1.37.5 antes de que nadie los leyera — perdimos la
   causa raíz. Un nodo drenado y roto es un **laboratorio en vivo**: sus pods
   siguen ahí para inspeccionar.

**ANTES de cualquier reversión, capturar** (esto es lo que faltó):

```bash
kubectl -n kube-system logs <pod-envoy-1.37.5-del-nodo> > /tmp/4a-v3/envoy-victima.log
kubectl -n kube-system logs <pod-cilium-1.20.1-del-nodo> > /tmp/4a-v3/agente-victima.log
kubectl -n kube-system exec <pod-cilium-del-nodo> -- cilium-dbg status --all-addresses > /tmp/4a-v3/dbg-victima.txt
```

**Reversión de ese nodo** (si dirección decide revertir en vez de investigar):
con `OnDelete` **no hay `helm rollback` por nodo** — el rollback de helm cambia
la plantilla y hay que borrar los pods igualmente. Procedimiento:
`helm rollback cilium -n kube-system` → borrar a mano los pods de los nodos ya
rodados → esperar Ready → re-registrar y superar la probation de cada uno
(§2.8).
Medido en intentos anteriores: **67 s** (24-ago) y **86 s** (23-ago), pero
aquellos eran RollingUpdate; con OnDelete el tiempo lo marca el operador.

**Las CRDs v1.6.1 se quedan.** 1.19.6 las tolera — es el estado en que vivió
toda la escalera de 4b, con el gate 6a/6b verde en cada escalón. Degradarlas
sería meter una segunda variable en mitad de un incidente.

## 5. Instrumentación en vivo — arranca ANTES de la fase 1

```bash
# REPO_ROOT, WITNESS_STATE_DIR, /tmp/4a-v3 y el gate de grpcurl ya están
# creados en §0.a — este bloque solo AÑADE capturas al registro único.
# LÍNEA BASE, y solo eso. `kubectl logs -l ... -f` se engancha a los pods que
# EXISTEN al lanzarlo: no sigue a los que nacen después. Como el drenaje
# sustituye los doce, este seguimiento cubre los 1.19.6 y PERDERÍA los 1.20.1
# — justo los que importan si algo falla, que es la lección del 24-ago.
# Se conserva por el "antes", y NO se afirma que siga a los seis.
kubectl -n kube-system logs -l k8s-app=cilium-envoy -c cilium-envoy \
  -f --prefix --timestamps --max-log-requests=12 > /tmp/4a-v3/envoy-PRE.log 2>&1 &
echo "$!" >> /tmp/4a-v3/instrumentation.pids
kubectl -n kube-system logs -l k8s-app=cilium -c cilium-agent \
  -f --prefix --timestamps --max-log-requests=12 > /tmp/4a-v3/agent-PRE.log 2>&1 &
echo "$!" >> /tmp/4a-v3/instrumentation.pids
kubectl -n kube-system get events -w > /tmp/4a-v3/events.log 2>&1 &
echo "$!" >> /tmp/4a-v3/instrumentation.pids
# muestreador cada 5s: ambos DaemonSets, pods por nodo, y salud de AMBOS
# target groups (Gateway y API) — el del API es nuevo en v3, por §3
SAMPLE_GW_TG=$(aws elbv2 describe-target-groups --region eu-west-1 \
  --names "${CLUSTER_NAME:-k8s-vanilla-lab}-gw-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
SAMPLE_API_TG=$(aws elbv2 describe-target-groups --region eu-west-1 \
  --names "${CLUSTER_NAME:-k8s-vanilla-lab}-api-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
[ "$SAMPLE_GW_TG" != "None" ] && [ "$SAMPLE_API_TG" != "None" ] || {
  echo "✗ no se pudieron resolver ambos target groups para el muestreador"; exit 1;
}
(
  while true; do
    date -u +%Y-%m-%dT%H:%M:%SZ
    kubectl -n kube-system get ds cilium cilium-envoy \
      -o custom-columns='DS:.metadata.name,DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady,UPDATED:.status.updatedNumberScheduled'
    kubectl -n kube-system get pods -l 'k8s-app in (cilium,cilium-envoy)' \
      -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,START:.status.startTime'
    aws elbv2 describe-target-health --region eu-west-1 \
      --target-group-arn "$SAMPLE_GW_TG" --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' --output text
    aws elbv2 describe-target-health --region eu-west-1 \
      --target-group-arn "$SAMPLE_API_TG" --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' --output text
    sleep 5
  done
) > /tmp/4a-v3/sampler.log 2>&1 &
echo "$!" >> /tmp/4a-v3/instrumentation.pids

# En el testigo normal, GRPC_EVERY=5 significa una sonda gRPC cada ~10 s
# (HTTP va cada 2 s). Una ventana de nodo dura minutos y eso detectaría una
# caída sostenida, pero el 4a original empezó por gRPC y un fallo breve podría
# caber entre dos muestras. Durante 4a se elimina esa ventana: 1 gRPC por CADA
# ciclo HTTP durante los seis nodos.
WITNESS_GRPC_EVERY=1 bash "$REPO_ROOT/scripts/witness-traffic.sh" start "4a-v3-drenaje"
```

El testigo se abre **antes de la fase 1** con etiqueta `4a-v3-drenaje` y **no
se cierra hasta el final de los seis nodos**. La probation de §2.8 añade además
30 ciclos explícitos que exigen HTTP y gRPC OK después de cada reintegración;
el testigo continuo es una segunda red independiente, no su sustituto.

## 5.b CIERRE FINAL — ejecutable, tras los seis nodos

Nada de esto es opcional, y ninguna línea es prosa.

```bash
# 1. Los DOCE pods en la versión objetivo
AG=$(kubectl -n kube-system get pods -l k8s-app=cilium \
     -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep -c '1\.20\.1')
EV=$(kubectl -n kube-system get pods -l k8s-app=cilium-envoy \
     -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep -c 'v1\.37')
echo "  control: esperaba 6 agentes y 6 envoy en destino; encontré $AG y $EV"
[ "$AG" -eq 6 ] && [ "$EV" -eq 6 ] || { echo "✗ PARAR"; exit 1; }

# 2. Ambos DaemonSets convergidos: updated == desired
for D in cilium cilium-envoy; do
  U=$(kubectl -n kube-system get ds $D -o jsonpath='{.status.updatedNumberScheduled}')
  W=$(kubectl -n kube-system get ds $D -o jsonpath='{.status.desiredNumberScheduled}')
  echo "  $D updated=$U desired=$W"
  [ "$U" = "$W" ] || { echo "✗ $D no convergió → PARAR"; exit 1; }
done

# 3. KPR estricto sigue en pie
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -q 'KubeProxyReplacement:.*True' \
  || { echo "✗ KPR degradado → PARAR"; exit 1; }

# 4. El controlador de Gateway API está VIVO — canary, NUNCA Programmed (8ª cara)
bash scripts/verify-gateway-controller.sh post-4a || { echo "✗ controlador muerto → §4"; exit 1; }

# 5. RUTAS: aserción, no impresión. Un campo impreso no es un campo
#    verificado — esa confusión es la 8ª cara. Sale ≠0 si alguna ruta tiene
#    observedGeneration desfasado, le falta parent o condición, o no está
#    Accepted+ResolvedRefs. Y con CONTROL POSITIVO: una lista vacía satisface
#    vacuamente "ninguna mala", así que se exige el conjunto esperado.
kubectl get httproute,grpcroute -A -o json | jq -e '
  def bad:
    .metadata.generation as $g
    | ((.status.parents // []) | length) == 0
      or (any(.status.parents[];
            ((.conditions // []) | length) == 0
            or any(.conditions[]; (.observedGeneration // -1) != $g)
            or ((any(.conditions[]; .type=="Accepted"     and .status=="True")) | not)
            or ((any(.conditions[]; .type=="ResolvedRefs" and .status=="True")) | not)
         ));
  (.items | length) >= 2 and ([ .items[] | select(bad) ] | length) == 0
' >/dev/null || {
  echo "✗ rutas no vigentes o conjunto incompleto — detalle:"
  kubectl get httproute,grpcroute -A -o json | jq -r '.items[] |
    "   \(.kind) \(.metadata.name) gen=\(.metadata.generation) " +
    ([.status.parents[]?.conditions[]?|"\(.type)=\(.status)(obs:\(.observedGeneration))"]|join(" "))'
  exit 1
}
echo "  ✓ rutas: >=2 presentes, todas Accepted+ResolvedRefs con obs==gen"

# 6. Hubble responde
kubectl -n kube-system get deploy hubble-relay -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]' \
  || { echo "✗ hubble-relay sin réplicas listas"; exit 1; }

# 7. VEREDICTO del testigo — cierra la ventana de los seis nodos
bash "$REPO_ROOT/scripts/witness-traffic.sh" stop

# 8. INSTRUMENTACIÓN PARADA DE VERDAD. El bloque declara que nada es
#    opcional; entonces el código FALLA, no advierte. Y LEFT cuenta TODOS los
#    tipos —logs, events -w, muestreador—, no solo kubectl logs.
while read -r P; do [ -n "$P" ] && kill "$P" 2>/dev/null; done < /tmp/4a-v3/instrumentation.pids
sleep 3
while read -r P; do [ -n "$P" ] && kill -9 "$P" 2>/dev/null; done < /tmp/4a-v3/instrumentation.pids
sleep 2
count_instrumentation() {
  { pgrep -f 'kubectl -n kube-system logs' || true
    pgrep -f 'kubectl -n kube-system get events -w' || true
    pgrep -f '4a-v3/sampler' || true
    while read -r P; do [ -n "$P" ] && kill -0 "$P" 2>/dev/null && echo "$P"; done < /tmp/4a-v3/instrumentation.pids
  } | sort -u | grep -c . || true
}
LEFT=$(count_instrumentation)
echo "  control: esperaba 0 procesos de instrumentación vivos, quedan $LEFT"
[ "$LEFT" -eq 0 ] || { echo "✗ instrumentación colgada: la ceremonia NO está cerrada"; exit 1; }
ls -la /tmp/4a-v3/ | tail -n +2
```

### Decisión EXPLÍCITA sobre `updateStrategy`

Al terminar, los DaemonSets **quedan en `OnDelete`**. Eso no es un residuo: es
un estado que alguien tiene que **decidir**, y dejarlo sin decidir significa
que el próximo upgrade rodará —o no— según lo que nadie eligió.

| Opción | Consecuencia |
|---|---|
| **Conservar `OnDelete`** | Ningún cambio de plantilla rueda solo. Más seguro, pero **un parche de seguridad tampoco se aplicará** hasta que alguien borre pods a mano |
| **Restaurar `RollingUpdate`** | Vuelve el comportamiento por defecto — y con él el modo de fallo de 4a, si algún día se rueda sin drenar |

**Hay que escribir cuál se elige y por qué**, aquí, con fecha. Un DaemonSet en
`OnDelete` que nadie recuerda es una bomba de relojería silenciosa: parecerá
que los upgrades futuros "no hacen nada".

## 6. Qué esperamos en el testigo, y por qué esta vez sí

**Cero pérdida es ahora una expectativa razonable, no una esperanza**: en
ningún instante se rueda un target que siga en el pool. AWS confirma su baja,
se rueda, vuelve a registrarse y no se permite tocar el siguiente hasta que
supere la probation sostenida con el testigo paralelo intacto.

**El límite honesto que queda**: ninguna muestra finita demuestra las mil
peticiones futuras. Lo que sí eliminamos es el salto de fe de una sola sonda:
tras `register-targets`, el nodo participa en el tráfico real durante al menos
60 s y 30 ciclos HTTP+gRPC consecutivos, mientras el testigo continuo observa
el mismo NLB en paralelo. Cualquier fallo pausa; no existe presupuesto de
pérdida aceptable.
