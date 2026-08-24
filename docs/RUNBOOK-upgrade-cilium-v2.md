# RUNBOOK — 4a-v2: Cilium 1.19.6 → 1.20.1 con captura en vivo

**Pieza**: S2-4, segundo movimiento, **segundo intento** · **ADR**: [ADR-008](decisions/ADR-008-upgrade-path.md)
**Estado**: PREPARADO, NO EJECUTADO. Requiere respuesta a las preguntas de §6.
**Punto de partida**: Cilium 1.19.6 · CRDs Gateway API v1.6.1 · gate
`SCHEMA READY FOR 4a` verde · 4b coronado 2726/2726.

> **Por qué hay un v2.** El intento del 24-ago no falló por lo del 23 (cero
> `transport:tls`, gate de entrada verde): fue un fallo NUEVO cuya causa raíz
> **no se pudo leer**, porque el rollback recreó los pods y se llevó los logs
> de Envoy 1.37.5. Recuperar la puerta era lo correcto; el coste fue el
> diagnóstico. Este runbook existe para que la próxima pasada **capture la
> causa mientras ocurre**, no después.
>
> Y trae un hallazgo que invalida la premisa del v1: **`externalTrafficPolicy:
> Cluster` no absorbe el hueco** (INCIDENTS #20). Perder un Envoy cuesta el
> tercio de tráfico que el NLB manda a ese nodo, y el health check TCP sobre
> el NodePort no puede detectarlo.

## 1. Instrumentación de captura — ANTES del helm

Todo esto arranca **antes** de tocar helm y sigue corriendo durante el rollout.

```bash
mkdir -p /tmp/4a-v2 && cd /tmp/4a-v2

# (a) Logs de TODOS los Envoy, en seguimiento, a fichero. La pieza que faltó.
kubectl -n kube-system logs ds/cilium-envoy -f --prefix --timestamps \
  > envoy-all.log 2>&1 &
echo $! > envoy-logs.pid

# (b) Logs del agente, por lo mismo
kubectl -n kube-system logs ds/cilium -f --prefix --timestamps \
  > agent-all.log 2>&1 &
echo $! > agent-logs.pid

# (c) Eventos del namespace, en vivo
kubectl -n kube-system get events -w > events.log 2>&1 &
echo $! > events.pid

# (d) Muestreador cada 5s: DaemonSets, targets del NLB, y KPR por nodo
cat > sampler.sh <<'EOF'
TG=$(aws elbv2 describe-target-groups --region eu-west-1 \
  --query "TargetGroups[?Port==\`30443\`].TargetGroupArn" --output text)
while true; do
  TS=$(date -u +%H:%M:%SZ)
  A=$(kubectl -n kube-system get ds cilium -o jsonpath='{.status.updatedNumberScheduled}/{.status.numberReady}')
  E=$(kubectl -n kube-system get ds cilium-envoy -o jsonpath='{.status.updatedNumberScheduled}/{.status.numberReady}')
  POD=$(kubectl -n kube-system get pods -l k8s-app=cilium-envoy \
    -o custom-columns='N:.spec.nodeName,S:.status.phase,R:.status.containerStatuses[0].ready,I:.spec.containers[0].image' \
    --no-headers 2>/dev/null | sed 's/quay.io.cilium.cilium-envoy://' | tr '\n' ';')
  TGT=$(aws elbv2 describe-target-health --region eu-west-1 --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text | tr '\n' ';')
  echo "$TS ds_agent=$A ds_envoy=$E | pods=$POD | targets=$TGT"
done
EOF
bash sampler.sh > sampler.log 2>&1 &
echo $! > sampler.pid
```

**Parada de la instrumentación** (al final, pase lo que pase):
`for f in *.pid; do kill "$(cat $f)" 2>/dev/null; done`

## 2. Hipótesis verificables de por qué `Cluster` no absorbió

Las tres se contrastan con los datos que captura §1. **H1 y H3 ya están
verificadas como HECHO** sobre el cluster vivo; queda H2, que es la única que
explica el *retraso*.

| # | Hipótesis | Estado | Cómo se decide con la captura |
|---|---|---|---|
| **H1** | *`Cluster` no tiene a dónde repartir*: el Service del Gateway no tiene selector y su único endpoint es un placeholder sin `nodeName`; el CEC no tiene `nodeSelector`, así que cada nodo sirve con **su** Envoy local o no sirve. | **VERIFICADO** (post-incidente) | Ya no es hipótesis. Explica por qué cae el tercio entero. |
| **H2** | *El Envoy nuevo tarda en aceptar*: el pod pasa a `Ready` antes de haber recibido su listener por xDS, así que la ventana de rechazo dura más que el reinicio. | **ABIERTA — es la que falta** | `envoy-all.log`: intervalo entre el arranque del contenedor y `lds: add/update listener`. Contrastar con el primer `transport` del testigo. Si el listener llega tarde, H2 confirmada. |
| **H3** | *El health check no puede verlo*: es TCP al NodePort 30443, que Cilium programa en todo nodo con independencia de Envoy; nunca marca `unhealthy`. | **VERIFICADO** (config del TG) | `sampler.log`: si los 3 targets siguen `healthy` mientras el testigo falla, queda demostrado en vivo. |

**La pregunta que H2 responde**: ¿el hueco es de segundos (arranque de Envoy)
o de minutos (convergencia xDS que no llega)? El 24-ago no recuperó en ~3,5
minutos, lo que apunta a que **no era un hueco de arranque**.

## 3. Pre-flight y gate de entrada

Sin cambios respecto al v1, ambos pasaron el 24-ago:
```bash
bash scripts/preflight-cilium-upgrade.sh 1.20.1
bash scripts/verify-cilium-120-schema.sh || exit 1
```

## 4. El helm — pendiente de la decisión de §6

```bash
helm upgrade cilium cilium/cilium --version 1.20.1 --namespace kube-system \
  -f /tmp/cilium-live-values.yaml \
  --set envoy.updateStrategy.rollingUpdate.maxUnavailable=1 \
  --wait --timeout 10m
```

> `maxUnavailable=1` **no fue el problema y no es la solución**: la
> degradación empezó con el primer Envoy. Bajar el paralelismo no ayuda
> cuando el coste de un solo nodo ya es un tercio del tráfico. Ver §6.

## 5. Criterio de aborto — el discriminador, sin cambios

| Racha de fallos consecutivos | Lectura | Acción |
|---|---|---|
| 1–3 con recuperación | reconexión transitoria | anotar |
| 4–9 | zona gris | parar el reloj, mirar `sampler.log` |
| **≥10 o sin recuperar** | **puerta caída** | **`helm rollback cilium -n kube-system`** |

Medido: 23-ago → racha 128 · 24-ago → racha 35 · 4b → 0.

**Antes de hacer rollback**, si el tiempo lo permite y la puerta ya está
caída de todos modos: `kubectl -n kube-system logs <pod-envoy-1.37.5> > /tmp/4a-v2/envoy-victima.log`.
El rollback destruye esos logs — es lo que pasó el 24-ago.

## 6. PREGUNTAS ABIERTAS — no se reintenta sin respuesta

1. **¿Existe una estrategia de rollout que drene el nodo del NLB ANTES de
   rodar su Envoy?** Con endpoints placeholder y health check TCP al
   NodePort, el NLB no puede descubrirlo solo. Opciones a evaluar: desregistrar
   el target a mano antes de cada nodo; cambiar el health check a HTTP/HTTPS
   contra el listener del Gateway (que sí prueba Envoy); o `PreStop` en el
   DaemonSet de Envoy que dé margen.
2. **¿`maxUnavailable=1` sobre 3 workers sigue siendo agresivo?** Los datos
   dicen que el parámetro es **irrelevante** para este modo de fallo — pero
   confirmarlo antes de descartarlo.
3. **¿Es aceptable un upgrade de Envoy con corte por nodo**, dado que el
   Gateway sirve desde el Envoy local sin par al que recurrir? Si lo es, 4a
   necesita ventana de mantenimiento en vez de expectativa de cero pérdida.

## 7. Post-upgrade (si se llega)

Idéntico al v1: ambos DaemonSets 6/6, Envoy `v1.37.x`,
`KubeProxyReplacement: True`, gate 6a/6b, y el Gateway con
`verify-gateway-controller.sh` — **nunca `Programmed`**.

## 8. Rollback

`helm rollback cilium -n kube-system`. Medido: **67 s** el 24-ago (86 s el
23-ago). Las **CRDs v1.6.1 se quedan**: 1.19.6 las tolera, es el estado en que
vivió toda la escalera de 4b.
