#!/usr/bin/env bash
# WITNESS — the measuring instrument for the piece-4 upgrades.
#
# Usage:
#   scripts/witness-traffic.sh start <label>   # begin a measured window
#   scripts/witness-traffic.sh stop            # end it and print the verdict
#   scripts/witness-traffic.sh once            # one probe, for smoke-style checks
#
# WHY THIS EXISTS AND NOT THE APP'S traffic-generator: that one is a LOAD
# generator and says so in its own code — "Failures are logged, never fatal:
# targets may be rolling." Perfect for producing traffic, useless as
# evidence: it swallows exactly what an upgrade witness must count.
#
# This measures instead, and from OUTSIDE, through the NLB — the single
# entry path crowned in piece 2 and the thing each upgrade could break.
#
# THE VERDICT IS EXACT-SET, NOT A RATE: sent == successful, or the window
# failed. There is no "99.8% is fine" here; a lost request during a rolling
# upgrade is the whole finding. Every non-success is CLASSIFIED, because
# "it failed" does not tell you whether the datapath dropped, the endpoint
# went away or the app answered something unexpected:
#
#   transport   — connection refused/reset, TLS failure, DNS: the path broke
#   timeout     — no answer inside the deadline: the path hung
#   http        — an answer we did not expect: the app or the route changed
#   grpc        — a non-OK gRPC status over the same door
#
# An UNCLASSIFIABLE outcome counts as a failure (INCIDENTS #17): a witness
# that cannot tell what happened has not witnessed anything.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
HOST="${WITNESS_HOST:-shipments.logistics.lab}"
INTERVAL="${WITNESS_INTERVAL:-2}"          # seconds between probes
GRPC_EVERY="${WITNESS_GRPC_EVERY:-5}"      # one gRPC probe every N HTTP probes
STATE_DIR="${WITNESS_STATE_DIR:-/tmp/witness-${CLUSTER_NAME}}"

log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }

resolve_endpoint() {
  NLB_DNS=$(aws elbv2 describe-load-balancers --names "${CLUSTER_NAME}-gw-nlb" \
    --region "${AWS_REGION}" --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null) \
    || FAIL "cannot resolve the NLB endpoint — is the cluster up?"
  [ -n "${NLB_DNS}" ] && [ "${NLB_DNS}" != "None" ] || FAIL "empty NLB DNS"
  # Pin to the live Gateway certificate: the selfsigned CA has an empty DN
  # and LibreSSL will not verify it (S1 finding), so pinning is how we get
  # real TLS verification instead of -k blindness.
  GW_PIN=$(kubectl get secret -n infra shared-gw-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary | base64) || FAIL "cannot read the Gateway certificate"
}

# probe_http → prints "ok" | "transport" | "timeout" | "http:<code>"
probe_http() {
  local body code rc
  body=$(printf '{"reference":"witness-%s","origin":"MAD","destination":"BCN"}' "$(date -u +%s%N)")
  set +e
  code=$(curl -s --max-time 10 \
    --pinnedpubkey "sha256//${GW_PIN}" \
    --connect-to "${HOST}:443:${NLB_DNS}:443" \
    -H 'Content-Type: application/json' -d "${body}" \
    -o /dev/null -w '%{http_code}' "https://${HOST}/shipments" 2>/dev/null)
  rc=$?
  set -e
  case "${rc}" in
    0)  case "${code}" in
          200|201) echo "ok" ;;
          *)       echo "http:${code}" ;;
        esac ;;
    28) echo "timeout" ;;
    *)  echo "transport" ;;   # 7 refused, 35 TLS, 6 DNS, 56 reset…
  esac
}

# probe_grpc → "ok" | "grpc" | "skip" (grpcurl absent)
probe_grpc() {
  command -v grpcurl >/dev/null 2>&1 || { echo "skip"; return; }
  set +e
  grpcurl -insecure -authority "${HOST}" -max-time 10 \
    -d '{"origin":"MAD","destination":"BCN"}' \
    "${NLB_DNS}:443" logistics.routing.v1.RoutingService/CalculateRoute >/dev/null 2>&1
  local rc=$?
  set -e
  [ ${rc} -eq 0 ] && echo "ok" || echo "grpc"
}

cmd_start() {
  local label="${1:-window}"
  mkdir -p "${STATE_DIR}"
  [ -f "${STATE_DIR}/pid" ] && kill -0 "$(cat "${STATE_DIR}/pid")" 2>/dev/null \
    && FAIL "a witness window is already running (pid $(cat "${STATE_DIR}/pid")) — stop it first"
  resolve_endpoint
  : > "${STATE_DIR}/series"
  echo "${label}" > "${STATE_DIR}/label"
  date -u +%Y-%m-%dT%H:%M:%SZ > "${STATE_DIR}/started"
  echo "${NLB_DNS}" > "${STATE_DIR}/endpoint"
  (
    n=0
    while true; do
      n=$((n + 1))
      r=$(probe_http)
      echo "$(date -u +%H:%M:%SZ) http ${r}" >> "${STATE_DIR}/series"
      if [ $((n % GRPC_EVERY)) -eq 0 ]; then
        g=$(probe_grpc)
        [ "${g}" != "skip" ] && echo "$(date -u +%H:%M:%SZ) grpc ${g}" >> "${STATE_DIR}/series"
      fi
      sleep "${INTERVAL}"
    done
  ) &
  echo $! > "${STATE_DIR}/pid"
  log "witness OPEN — label '${label}', endpoint ${NLB_DNS}, one probe every ${INTERVAL}s"
  log "close it with: bash $0 stop"
}

cmd_stop() {
  [ -f "${STATE_DIR}/pid" ] || FAIL "no witness window is open"
  kill "$(cat "${STATE_DIR}/pid")" 2>/dev/null || true
  rm -f "${STATE_DIR}/pid"
  local label started
  label=$(cat "${STATE_DIR}/label"); started=$(cat "${STATE_DIR}/started")
  SERIES="${STATE_DIR}/series" LABEL="${label}" STARTED="${started}" \
    ENDPOINT="$(cat "${STATE_DIR}/endpoint")" python3 - <<'PY'
import os, collections
series = [l.split() for l in open(os.environ["SERIES"]) if l.strip()]
kinds = collections.Counter()
first_fail = None
for ts, proto, result in series:
    kinds[result if result == "ok" else result.split(":")[0]] += 1
    if result != "ok" and first_fail is None:
        first_fail = (ts, proto, result)
sent = len(series)
ok = kinds["ok"]
print("")
print("=== WITNESS WINDOW '%s' ===" % os.environ["LABEL"])
print("  endpoint : %s" % os.environ["ENDPOINT"])
print("  from     : %s" % os.environ["STARTED"])
print("  sent     : %d" % sent)
print("  successful: %d" % ok)
for k in ("transport", "timeout", "http", "grpc"):
    if kinds[k]:
        print("  %-9s: %d" % (k, kinds[k]))
print("")
if sent == 0:
    print("✗ VERDICT: the window recorded NOTHING — a witness with no probes is not evidence")
    raise SystemExit(1)
if ok == sent:
    print("✓ VERDICT: sent == successful (%d/%d) — the entry path never broke" % (ok, sent))
    raise SystemExit(0)
print("✗ VERDICT: %d of %d probes did NOT succeed" % (sent - ok, sent))
print("  first failure: %s %s %s" % first_fail)
raise SystemExit(1)
PY
}

cmd_once() {
  resolve_endpoint
  local r; r=$(probe_http)
  [ "${r}" = "ok" ] || FAIL "single probe failed: ${r}"
  local g; g=$(probe_grpc)
  case "${g}" in
    ok)   log "✓ HTTP and gRPC both answered through the NLB" ;;
    skip) log "✓ HTTP answered through the NLB (grpcurl absent — gRPC not probed)" ;;
    *)    FAIL "gRPC probe failed through the NLB" ;;
  esac
}

case "${1:-}" in
  start) shift; cmd_start "${1:-window}" ;;
  stop)  cmd_stop ;;
  once)  cmd_once ;;
  *) echo "usage: $0 {start <label>|stop|once}" >&2; exit 2 ;;
esac
