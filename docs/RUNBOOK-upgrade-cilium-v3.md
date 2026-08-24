# RUNBOOK — 4a-v3: Cilium 1.19.6 → 1.20.1 por DRENAJE COORDINADO

**Pieza**: S2-4, segundo movimiento, **tercer intento** · **ADR**: [ADR-008](decisions/ADR-008-upgrade-path.md)
**Estado**: PREPARADO, NO EJECUTADO.
**Punto de partida**: Cilium 1.19.6 · CRDs Gateway API v1.6.1 · gate
`SCHEMA READY FOR 4a` verde · 4b coronado 2726/2726.

> **El cambio de estrategia.** v1 y v2 buscaban que el balanceador **detectara**
> el nodo caído. Esto es imposible de hacer bien en esta topología: el HC del
> NLB en TCP es ciego a Envoy, y en HTTPS no puede validar un CA de DN vacío ni
> manda SNI. Así que dejamos de depender de la detección y pasamos al
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

## 1. Paso previo: `OnDelete` confirmado ANTES de tocar versiones

El riesgo que esto evita: si el mismo `helm upgrade` introdujera `OnDelete`
**y** la imagen nueva, la transición sería una carrera — y apostar a que el
controlador lea la estrategia nueva antes de rodar es exactamente la clase de
suposición que llevamos dos intentos pagando.

**Dos fases de helm, y la primera NO cambia versiones:**

```bash
# FASE 1 — misma versión 1.19.6, solo la estrategia. Nada debe rodar.
helm upgrade cilium cilium/cilium --version 1.19.6 \
  --namespace kube-system -f /tmp/cilium-live-values.yaml \
  --set updateStrategy.type=OnDelete \
  --set envoy.updateStrategy.type=OnDelete \
  --wait --timeout 5m

# VERIFICACIÓN DURA, con aserción de control (INCIDENTS #19)
for D in cilium cilium-envoy; do
  T=$(kubectl -n kube-system get ds "$D" -o jsonpath='{.spec.updateStrategy.type}')
  echo "  $D → $T"
  [ "$T" = "OnDelete" ] || { echo "✗ $D NO está en OnDelete → NO CONTINUAR"; exit 1; }
done

# Y que la fase 1 no rodó nada: mismas imágenes, mismos pods
kubectl -n kube-system get ds cilium cilium-envoy \
  -o custom-columns='NAME:.metadata.name,IMG:.spec.template.spec.containers[0].image,READY:.status.numberReady'
kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{range .items[*]}{.metadata.name} {.status.startTime}{"\n"}{end}'
#   → las startTime deben ser ANTERIORES a la fase 1
```

**Solo con `OnDelete` confirmado en ambos** se pasa a la fase 2.

```bash
# FASE 2 — la versión. Con OnDelete, NINGÚN pod rueda por sí solo.
helm upgrade cilium cilium/cilium --version 1.20.1 \
  --namespace kube-system -f /tmp/cilium-live-values.yaml \
  --set updateStrategy.type=OnDelete \
  --set envoy.updateStrategy.type=OnDelete \
  --set upgradeCompatibility=1.19 \
  --wait --timeout 10m
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

# 2.2 ESPERAR a que el drenaje termine de verdad — no dormir un número.
#     'draining' → 'unused' es la transición que dice que no quedan
#     conexiones en vuelo. Con timeout, y el timeout es FALLO.
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

# 2.6 PROBAR EL DATAPATH DE ESE NODO — el camino real, no una condición.
#     Aquí sí controlamos el cliente, así que el problema que hundió el
#     agregador (el HC del NLB no puede con TLS selfsigned ni manda SNI) no
#     existe: usamos curl con -k y --connect-to contra ESE nodo.
NODE_IP=$(kubectl get node $W -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
curl -sS -k --max-time 10 \
  --connect-to "datapath-probe.logistics.lab:443:${NODE_IP}:30443" \
  -o /dev/null -w '  datapath %{http_code}\n' \
  https://datapath-probe.logistics.lab/
#   → CUALQUIER código HTTP es PASS: prueba NodePort + TLS + cadena de Envoy.
#     Un 404 es el resultado esperado (ninguna ruta reclama ese nombre) y
#     demuestra el datapath sin depender de la app.
#   → 000 / fallo de conexión = ese nodo NO sirve → ir a §4, NO re-registrar.

# 2.7 DEVOLVER al pool y esperar healthy
aws elbv2 register-targets --region eu-west-1 --target-group-arn "$TG" \
  --targets Id=$I,Port=30443
aws elbv2 wait target-in-service --region eu-west-1 --target-group-arn "$TG" --targets Id=$I

# 2.8 CIERRE DEL NODO: los 3 healthy otra vez, y el testigo intacto
H=$(aws elbv2 describe-target-health --region eu-west-1 --target-group-arn "$TG" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
echo "  esperaba 3 healthy, encontré $H"
[ "$H" -eq 3 ] || { echo "✗ PARAR"; exit 1; }
bash scripts/witness-traffic.sh status
```

**Entre nodo y nodo se para y se mira el testigo.** Si la racha de fallos
consecutivos llega a **≥10**, se aborta y se va a §4 (discriminador validado:
23-ago → 128, 24-ago → 35, 4b → 0).

## 3. Los control planes — plano separado

**Hallazgo de Codex, y hay que acotarlo con honestidad.** Los agentes de los
CPs también ruedan. Lo que NO está establecido es cuánto afecta al API server:
`kube-apiserver` es un pod estático en `hostNetwork` escuchando directamente
en `:6443`, y el NLB apunta a `IP-del-CP:6443` como target de instancia — ese
camino **no** es un Service ni pasa por traducción de NodePort. Es plausible
que el reinicio del agente no lo corte.

**Pero "es plausible" es exactamente lo que nos ha costado dos intentos**, así
que se drena igual: cuesta 30 segundos por CP y elimina la pregunta.

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
#     … esperar 'unused' con el mismo bucle de §2.2

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

# 3.5 Ese CP vuelve a servir el API por su propia IP, antes de re-registrarlo
CP_IP=$(kubectl get node $C -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
curl -sS -k --max-time 10 -o /dev/null -w '  api %{http_code}\n' https://${CP_IP}:6443/readyz
#   → 401 o 403 es PASS: el API contestó. 000 = no sirve → NO re-registrar.

# 3.6 Devolver y esperar
aws elbv2 register-targets --region eu-west-1 --target-group-arn "$TGAPI" --targets Id=$J,Port=6443
aws elbv2 wait target-in-service --region eu-west-1 --target-group-arn "$TGAPI" --targets Id=$J
# 3.7 etcd 3/3 y 3 CPs healthy antes del siguiente
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
rodados → esperar Ready → probar el datapath de cada uno (§2.6) → re-registrar.
Medido en intentos anteriores: **67 s** (24-ago) y **86 s** (23-ago), pero
aquellos eran RollingUpdate; con OnDelete el tiempo lo marca el operador.

**Las CRDs v1.6.1 se quedan.** 1.19.6 las tolera — es el estado en que vivió
toda la escalera de 4b, con el gate 6a/6b verde en cada escalón. Degradarlas
sería meter una segunda variable en mitad de un incidente.

## 5. Instrumentación en vivo — arranca ANTES de la fase 1

```bash
mkdir -p /tmp/4a-v3 && cd /tmp/4a-v3
kubectl -n kube-system logs ds/cilium-envoy -f --prefix --timestamps > envoy-all.log 2>&1 &
kubectl -n kube-system logs ds/cilium       -f --prefix --timestamps > agent-all.log 2>&1 &
kubectl -n kube-system get events -w > events.log 2>&1 &
# muestreador cada 5s: ambos DaemonSets, pods por nodo, y salud de AMBOS
# target groups (Gateway y API) — el del API es nuevo en v3, por §3
bash sampler.sh > sampler.log 2>&1 &
```

El testigo se abre **antes de la fase 1** con etiqueta `4a-v3-drenaje` y **no
se cierra hasta el final de los seis nodos**.

## 6. Qué esperamos en el testigo, y por qué esta vez sí

**Cero pérdida es ahora una expectativa razonable, no una esperanza**: en
ningún instante se toca un nodo que esté recibiendo tráfico. El nodo sale del
pool, se prueba que no le llega nada, se rueda, se prueba que sirve, y solo
entonces vuelve.

**El límite honesto que queda**: durante `register-targets` hay una ventana en
la que el NLB empieza a mandar tráfico al nodo recién devuelto. Si su datapath
estuviera *funcionando a medias* —no roto del todo, que §2.6 detectaría— habría
pérdida. La sonda de §2.6 es una petición; no prueba las mil siguientes.

Discriminador, sin cambios: racha **1-3** = reconexión · **≥10** = puerta
caída, abortar.
