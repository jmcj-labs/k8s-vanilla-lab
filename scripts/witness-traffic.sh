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
# The gRPC door is a DIFFERENT authority. The chart composes hostnames as
# <hostname|service-name>.<domain>, so the GRPCRoute answers to
# routing.logistics.lab while HTTP answers to shipments.logistics.lab.
# Probing gRPC with the HTTP authority does not match the route: every gRPC
# probe fails and the window is failed by the instrument, not by the cluster.
# The other way for a witness to be worthless — failing what it should pass.
GRPC_HOST="${WITNESS_GRPC_HOST:-routing.logistics.lab}"
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
  # -k IS REQUIRED and does NOT weaken this. The selfsigned CA has an empty
  # DN, so chain verification cannot succeed (S1 finding) and curl returns 60
  # on every request — which classified as transport:tls and would have failed
  # EVERY window of 4a with a fault that was ours. Pinning is enforced
  # independently of -k: proven live, a wrong pin still returns curl 90.
  code=$(curl -s -k --max-time 10 \
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
    90|35|60|58|77) echo "transport:tls" ;;   # 90 = pin mismatch: THE rotated-cert signature
    6|7|56)      echo "transport" ;;       # DNS, refused, reset
    *)  echo "probe-error:curl-rc-${rc}" ;; # unknown curl failure: OURS, not the cluster's
  esac
}

# probe_grpc → "ok" | "grpc" | "skip" (grpcurl absent)
probe_grpc() {
  command -v grpcurl >/dev/null 2>&1 || { echo "skip"; return; }
  set +e
  grpcurl -insecure -authority "${GRPC_HOST}" -max-time 10 \
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
      # Evidence that the loop is WORKING, stamped before the probe so a
      # hung probe shows up as a stale heartbeat rather than as silence.
      date -u +%s > "${STATE_DIR}/heartbeat"
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

# Worst legitimate silence between two heartbeats: an HTTP probe at its
# --max-time, a gRPC probe at its own, the sleep, and slack for a loaded box.
hb_tolerance() { echo "${WITNESS_HB_TOLERANCE:-$((10 + 10 + INTERVAL + 10))}"; }

cmd_stop() {
  [ -f "${STATE_DIR}/pid" ] || FAIL "no witness window is open"
  # THE HOLE THIS CLOSES: if the probing loop died halfway, the series simply
  # stops growing — and a verdict computed over what it managed to collect
  # would read sent == successful and PASS a window that stopped witnessing.
  # A witness that died is not a witness that saw nothing wrong.
  #
  # THE HOLE THE FIRST FIX STILL HAD: liveness was `kill -0 <pid>`, which
  # asks "does a process with this number exist" — not "was my loop still
  # working". It answers YES for a PID the OS recycled onto some unrelated
  # process, and YES for a loop wedged and probing nothing. Both are exactly
  # the failure this check exists to catch: the watchdog inheriting the bug
  # it watches. Liveness is now the loop's own HEARTBEAT — evidence of work
  # done, stamped by the loop itself, immune to PID reuse.
  local wpid hb now age tol
  wpid=$(cat "${STATE_DIR}/pid")
  [ -f "${STATE_DIR}/heartbeat" ] || { kill "${wpid}" 2>/dev/null || true
    FAIL "the window left NO heartbeat: the loop never completed an iteration.
  There is nothing to give a verdict over."; }
  hb=$(cat "${STATE_DIR}/heartbeat")
  case "${hb}" in
    ''|*[!0-9]*) kill "${wpid}" 2>/dev/null || true
      FAIL "the heartbeat is unreadable ('${hb}') — the record of whether the
  witness was alive is itself damaged, so it cannot be read as alive." ;;
  esac
  now=$(date -u +%s); age=$((now - hb)); tol=$(hb_tolerance)
  kill "${wpid}" 2>/dev/null || true
  rm -f "${STATE_DIR}/pid"
  [ "${age}" -le "${tol}" ] || FAIL "the witness loop STOPPED WITNESSING ${age}s before
  the window closed (tolerance ${tol}s). Whatever it collected is a truncated
  record, not a verdict — the window must be re-run."

  # The verifier is held to its own rule: every input it needs must be
  # readable, or there is no verdict. Read them explicitly instead of inside
  # the command prefix, where a failing substitution passes an empty string.
  local label started endpoint
  label=$(cat "${STATE_DIR}/label")     || FAIL "cannot read the window label"
  started=$(cat "${STATE_DIR}/started") || FAIL "cannot read the window start"
  endpoint=$(cat "${STATE_DIR}/endpoint") || FAIL "cannot read the window endpoint"
  command -v python3 >/dev/null 2>&1 || FAIL "python3 is absent: the verdict cannot be
  computed, which is not the same as a window that passed."
  # A red verdict and a crashed verifier BOTH exit non-zero, so the exit code
  # alone cannot tell them apart — and reporting "the verifier did not
  # complete" over a perfectly good FAIL is a lie told during an incident,
  # when it is least affordable. The marker line is the discriminator: if the
  # verdict was printed, the verifier finished and did its job.
  local out rc
  out=$(SERIES="${STATE_DIR}/series" LABEL="${label}" STARTED="${started}" \
    ENDPOINT="${endpoint}" python3 "$(dirname "$0")/lib/witness-verdict.py" 2>&1) && rc=0 || rc=$?
  printf '%s\n' "${out}"
  if printf '%s' "${out}" | grep -q "VERDICT:"; then
    return "${rc}"   # verdict rendered — pass it through, red or green
  fi
  FAIL "the verifier did NOT reach a verdict (exit ${rc}) — no verdict was
  produced, so this window has NOT passed."
}

# IN-FLIGHT INSPECTION. A witness you cannot look at while it runs has the
# same disease as the ones fixed today: you are asked to trust a banner. This
# reads the state and NEVER touches the window — no kill, no verdict, no
# side effects. It reports what it can see and says so when it cannot.
cmd_status() {
  [ -d "${STATE_DIR}" ] || FAIL "no witness state at ${STATE_DIR}"
  [ -f "${STATE_DIR}/pid" ] || FAIL "no witness window is open"
  local label started endpoint hb now age tol sent ok
  label=$(cat "${STATE_DIR}/label" 2>/dev/null || echo "?")
  started=$(cat "${STATE_DIR}/started" 2>/dev/null || echo "?")
  endpoint=$(cat "${STATE_DIR}/endpoint" 2>/dev/null || echo "?")
  echo ""
  echo "=== WITNESS WINDOW '${label}' (OPEN) ==="
  echo "  endpoint : ${endpoint}"
  echo "  from     : ${started}"
  if [ -f "${STATE_DIR}/series" ]; then
    sent=$(awk '$3!="event"{n++} END{print n+0}' "${STATE_DIR}/series")
    ok=$(awk '$3!="event" && $4=="ok"{n++} END{print n+0}' "${STATE_DIR}/series")
    echo "  sent     : ${sent}"
    echo "  successful: ${ok}"
    [ "${sent}" = "${ok}" ] || {
      echo "  ⚠ $((sent - ok)) non-success so far — first:"
      awk '$3!="event" && $4!="ok"{print "     " $2, $3, $4; exit}' "${STATE_DIR}/series"; }
  else
    echo "  series   : ABSENT — nothing has been recorded"
  fi
  if [ -f "${STATE_DIR}/heartbeat" ]; then
    hb=$(cat "${STATE_DIR}/heartbeat"); now=$(date -u +%s); tol=$(hb_tolerance)
    case "${hb}" in ''|*[!0-9]*) echo "  heartbeat: UNREADABLE ('${hb}')" ;;
      *) age=$((now - hb))
         if [ "${age}" -le "${tol}" ]; then echo "  heartbeat: ${age}s ago (tolerance ${tol}s) — MEASURING"
         else echo "  heartbeat: ${age}s ago (tolerance ${tol}s) — ⚠ STALLED, this window will FAIL"; fi ;;
    esac
  else
    echo "  heartbeat: ABSENT — the loop has not completed an iteration"
  fi
  echo ""
  echo "  (read-only: the window is still open; close it with '$0 stop')"
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
  status) cmd_status ;;
  once)  cmd_once ;;
  *) echo "usage: $0 {start <label>|status|stop|once}" >&2; exit 2 ;;
esac
