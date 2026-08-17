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
  GW_PIN=$(gateway_pin) || FAIL "cannot read the Gateway certificate"
  GW_ISSUER=$(gateway_issuer) || FAIL "cannot read the Gateway certificate issuer"
}

gateway_pin() {
  kubectl get secret -n infra shared-gw-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary | base64
}
gateway_issuer() {
  kubectl get secret -n infra shared-gw-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d | openssl x509 -noout -issuer
}

# A pinned witness breaks the moment the certificate legitimately rotates —
# cert-manager renews, and 4c is a long window. Treating every TLS failure as
# "the cluster broke" would cry wolf; treating every new certificate as fine
# would make the pin decorative. So: on a TLS failure, re-read the live
# certificate. If the ISSUER is the one we started with, this is the expected
# rotation — re-pin and record it as an event. If the issuer changed, the
# door is presenting something we did not expect, and that IS a failure.
handle_possible_rotation() {
  local new_pin new_issuer
  new_pin=$(gateway_pin 2>/dev/null || true)
  new_issuer=$(gateway_issuer 2>/dev/null || true)
  if [ -z "${new_pin}" ] || [ -z "${new_issuer}" ]; then
    echo "cert-unreadable"; return
  fi
  if [ "${new_pin}" = "${GW_PIN}" ]; then
    echo "same-cert"; return          # TLS failed for another reason: real
  fi
  if [ "${new_issuer}" = "${GW_ISSUER}" ]; then
    GW_PIN="${new_pin}"
    echo "rotated-expected"; return
  fi
  echo "rotated-unexpected"
}

# probe_http → "ok" | "transport" | "timeout" | "http:<code>" | "probe-error:<why>"
#
# THE DISTINCTION THAT MATTERS: a failure to MEASURE is not a measurement.
# Blaming the cluster for our own broken tooling produces a false FAIL;
# treating an unparseable answer as a code produces a false PASS. Both are
# INCIDENTS #17 wearing different hats, so the two are separated explicitly
# and "probe-error" is its own class — it fails the window, and it says the
# fault was ours.
probe_http() {
  local body code rc
  command -v curl >/dev/null 2>&1 || { echo "probe-error:curl-missing"; return; }
  [ -n "${GW_PIN:-}" ] || { echo "probe-error:no-pin"; return; }
  [ -n "${NLB_DNS:-}" ] || { echo "probe-error:no-endpoint"; return; }
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
    0)
      # curl exited clean, so it HAS an answer — but only a well-formed
      # three-digit code counts as one. Anything else means we could not
      # read what happened, which is not the same as a bad status.
      case "${code}" in
        200|201)          echo "ok" ;;
        [1-5][0-9][0-9])  echo "http:${code}" ;;
        *)                echo "probe-error:unparseable-code" ;;
      esac ;;
    28) echo "timeout" ;;
    35|60|58|77) echo "transport:tls" ;;   # pin mismatch lives here
    6|7|56)      echo "transport" ;;       # DNS, refused, reset
    *)  echo "probe-error:curl-rc-${rc}" ;; # unknown curl failure: OURS, not the cluster's
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
      # A TLS failure may be a rotated certificate rather than a broken path.
      if [ "${r}" = "transport:tls" ]; then
        case "$(handle_possible_rotation)" in
          rotated-expected)
            echo "$(date -u +%s) $(date -u +%H:%M:%SZ) event cert-rotated-expected" >> "${STATE_DIR}/series"
            r=$(probe_http) ;;            # re-probe with the new pin
          rotated-unexpected)
            r="transport:unexpected-cert" ;;
          cert-unreadable)
            r="probe-error:cert-unreadable" ;;
        esac
      fi
      echo "$(date -u +%s) $(date -u +%H:%M:%SZ) http ${r}" >> "${STATE_DIR}/series"
      if [ $((n % GRPC_EVERY)) -eq 0 ]; then
        g=$(probe_grpc)
        [ "${g}" != "skip" ] && echo "$(date -u +%s) $(date -u +%H:%M:%SZ) grpc ${g}" >> "${STATE_DIR}/series"
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
  # THE HOLE THIS CLOSES: if the probing loop died halfway, the series simply
  # stops growing — and a verdict computed over what it managed to collect
  # would read sent == successful and PASS a window that stopped witnessing.
  # A witness that died is not a witness that saw nothing wrong. Liveness is
  # checked BEFORE the kill, so it is the loop's own state, not ours.
  WPID=$(cat "${STATE_DIR}/pid")
  if kill -0 "${WPID}" 2>/dev/null; then
    ALIVE=yes
  else
    ALIVE=no
  fi
  kill "${WPID}" 2>/dev/null || true
  rm -f "${STATE_DIR}/pid"
  [ "${ALIVE}" = "yes" ] || FAIL "the witness loop was ALREADY DEAD when the window closed.
  Whatever it collected is a truncated record, not a verdict — the window
  must be re-run. (This is why liveness is checked, not assumed.)"
  local label started
  label=$(cat "${STATE_DIR}/label"); started=$(cat "${STATE_DIR}/started")
  SERIES="${STATE_DIR}/series" LABEL="${label}" STARTED="${started}" \
    ENDPOINT="$(cat "${STATE_DIR}/endpoint")" python3 "$(dirname "$0")/lib/witness-verdict.py"
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
