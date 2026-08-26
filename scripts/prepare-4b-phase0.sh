#!/usr/bin/env bash
# 4b FASE 0 — la app viva y el testigo midiendo, ANTES de tocar una sola CRD.
#
# Vive en un script y no como bloque pegable por la misma razón que el resto
# de la ceremonia: un pegado en una terminal nueva perdería `set -e` a mitad,
# o heredaría un AWS_PROFILE de otro cluster. Se invoca desde
# `run-4b-rung.sh prepare`.
set -euo pipefail

# ── ESTE SCRIPT NO FIJA NADA: HEREDA Y EXIGE ────────────────────────────────
# Antes hacía `export AWS_PROFILE=k8s-vanilla-lab` en su segunda línea, así
# que MACHACABA lo que el padre le pasaba. El resultado posible era el peor:
# los applies de la escalera hablando con un cluster y el CORONATION y el
# testigo con otro, sin que nada lo dijera. Ahora falla si falta algo.
for V in AWS_PROFILE KUBECONFIG CLUSTER_NAME AWS_REGION WITNESS_STATE_DIR; do
  eval "val=\${$V:-}"
  [ -n "$val" ] || { echo "✗ $V no viene del padre — invoca 'run-4b-rung.sh prepare'" >&2; exit 1; }
done
echo "  heredado: profile=$AWS_PROFILE region=$AWS_REGION cluster=$CLUSTER_NAME"
echo "  heredado: kubeconfig=$KUBECONFIG testigo=$WITNESS_STATE_DIR"
REPO_ROOT=$(git rev-parse --show-toplevel)

# 0.1 grpcurl es prerrequisito DURO: sin él `once` devuelve "skip" en gRPC y
#     pasa igual, degradando el testigo a solo-HTTP sin avisar.
command -v grpcurl >/dev/null 2>&1 || { echo "✗ falta grpcurl"; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "✗ falta jq"; exit 1; }

# 0.2 Repo 2 desplegado, esperado SÍNCRONAMENTE (no "lanzar y confiar")
#     `--limit 1` cogería un run VIEJO o uno concurrente de otro. Se correlaciona
#     por hora de dispatch y evento, y se exige EXACTAMENTE uno.
DISPATCH_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run deploy.yml --repo jmcj-labs/logistics-lab
sleep 20
RUNS=$(gh run list --repo jmcj-labs/logistics-lab --workflow=deploy.yml --limit 20 \
       --json databaseId,createdAt,event \
       -q "[.[] | select(.event==\"workflow_dispatch\" and .createdAt >= \"$DISPATCH_TS\") | .databaseId]")
N=$(echo "$RUNS" | jq 'length')
echo "  control: esperaba 1 run despachado tras $DISPATCH_TS, encontré $N"
[ "$N" -eq 1 ] || { echo "✗ correlación ambigua ($N runs) → identificar a mano"; exit 1; }
RUN_ID=$(echo "$RUNS" | jq -r '.[0]')
gh run watch "$RUN_ID" --repo jmcj-labs/logistics-lab --exit-status \
  || { echo "✗ el deploy de Repo 2 no cerró verde (Build 502 → reintentar)"; exit 1; }

# 0.3 Sus rutas publicadas, por identidad exacta
kubectl get httproute,grpcroute -A -o json | jq -e '
  ([ .items[] | "\(.kind)/\(.metadata.namespace)/\(.metadata.name)" ] | sort)
  == ["GRPCRoute/logistics/routing","HTTPRoute/logistics/shipments-api"]
' >/dev/null || { echo "✗ las rutas de Repo 2 no son las esperadas"; exit 1; }

# 0.4 traffic-generator Ready, exigido
kubectl -n logistics wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=traffic-generator --timeout=180s \
  || { echo "✗ traffic-generator no está Ready"; exit 1; }

# 0.5 CADENA VIVA — CORONATION por el Gateway, literal, sin remitir a otro doc
NLB=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
      --names "${CLUSTER_NAME}-gw-nlb" --query 'LoadBalancers[0].DNSName' --output text)
PIN=$(kubectl get secret -n infra shared-gw-tls -o jsonpath='{.data.tls\.crt}' \
      | base64 -d | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
      | openssl dgst -sha256 -binary | base64)
REF="CORONATION-4B-$(date -u +%H%M%S)"
RESP=$(curl -sS -k --connect-to "shipments.logistics.lab:443:${NLB}:443" \
       --pinnedpubkey "sha256//${PIN}" -H 'Content-Type: application/json' \
       -d "{\"reference\":\"${REF}\",\"origin\":\"MAD\",\"destination\":\"BCN\"}" \
       https://shipments.logistics.lab/shipments)
ID=$(echo "$RESP" | jq -r '.id // empty')
[ -n "$ID" ] || { echo "✗ el POST no devolvió id: $RESP"; exit 1; }
#     … y los DOS eventos del pipeline (el campo es event_type, no type)
for i in $(seq 1 15); do
  EV=$(curl -sS -k --connect-to "shipments.logistics.lab:443:${NLB}:443" \
       --pinnedpubkey "sha256//${PIN}" \
       "https://shipments.logistics.lab/shipments/${ID}/events" \
       | jq -r '[.[].event_type] | sort | join(",")')
  [ "$EV" = "route.calculated,shipment.created" ] && break
  sleep 3
done
[ "$EV" = "route.calculated,shipment.created" ] \
  || { echo "✗ cadena incompleta: '$EV'"; exit 1; }
echo "  ✓ cadena viva: $REF ($ID) con ambos eventos"

# 0.6 TESTIGO — UNA sola apertura, y esperar EJECUTABLEMENTE a que mida
WITNESS_GRPC_EVERY=1 bash "$REPO_ROOT/scripts/witness-traffic.sh" start "4b-gwapi-crds"
for i in $(seq 1 20); do
  N=$(awk '$3!="event"{n++} END{print n+0}' "${WITNESS_STATE_DIR}/series" 2>/dev/null || echo 0)
  HB=$(cat "${WITNESS_STATE_DIR}/heartbeat" 2>/dev/null || echo 0)
  AGE=$(( $(date -u +%s) - HB ))
  [ "$N" -ge 5 ] && [ "$AGE" -le 32 ] && break
  sleep 3
done
echo "  control: esperaba >=5 sondas y latido <=32s; sondas=$N latido=${AGE}s"
[ "$N" -ge 5 ] && [ "$AGE" -le 32 ] || { echo "✗ el testigo no está midiendo"; exit 1; }
