#!/usr/bin/env bash
# PROVE THE GATEWAY API CONTROLLER IS WORKING — actively, on a resource it
# has never seen, by watching it do work it could not have done yesterday.
#
# WHY THIS EXISTS AND WHY IT IS NOT A LOG GREP OR A CONDITION READ.
#
# 4a passed every check the runbook named while the entry path was shut:
# helm `deployed`, both DaemonSets 6/6, Gateway `Programmed=True` with its
# address unchanged, app pods Running with zero restarts. The operator had
# silently skipped its Gateway API controller, and `Programmed=True` was a
# CACHE written by the previous operator that nobody was left to retract
# (INCIDENTS #17, eighth face).
#
# The first fix for that was to grep the operator log for the CRD error.
# That is the SAME BUG one level up: absence of a known error message is not
# evidence of work. A controller that never starts, starts and crashes,
# loses leader election, or is wedged produces no error we grep for either.
#
# So this proves the controller WORKS, by making it do something:
#   1. create a canary route it has never seen  → it must WRITE a status
#      naming itself as controller, with observedGeneration == generation
#   2. CHANGE that route                        → generation advances, and
#      observedGeneration must FOLLOW it
#
# Step 2 is what separates "a controller reconciled this once" from "a
# controller is reconciling now". A stale status cannot follow a generation
# it has never seen. Nothing here reads the pre-existing Gateway's
# conditions, on purpose: those are the very field that lied.
set -euo pipefail

NS="${CANARY_NS:-infra}"
GW="${GATEWAY_NAME:-shared-gw}"
CONTROLLER="${GATEWAY_CONTROLLER:-io.cilium/gateway-controller}"
TIMEOUT="${CANARY_TIMEOUT:-90}"
STEP="${1:-manual}"
NAME="witness-canary-$(echo "${STEP}" | tr -c 'a-z0-9' '-' | sed 's/-*$//')"

log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
OK()   { echo "  ✓ $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || FAIL "kubectl is absent"
kubectl get gateway "${GW}" -n "${NS}" >/dev/null 2>&1 \
  || FAIL "gateway ${NS}/${GW} not found — nothing to attach a canary to"

cleanup() { kubectl delete httproute "${NAME}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "=== active proof: is the Gateway API controller WORKING? (step '${STEP}') ==="

apply_canary() {
  local suffix="$1"
  kubectl apply -n "${NS}" -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${NAME}
  labels: {app.kubernetes.io/managed-by: witness-canary}
spec:
  parentRefs:
    - name: ${GW}
  hostnames: ["canary-${suffix}.witness.invalid"]
  rules:
    - matches:
        - path: {type: PathPrefix, value: /witness-${suffix}}
      backendRefs:
        - name: ${GW}-nonexistent-backend
          port: 8080
EOF
}

# Reads generation and the controller's observedGeneration for OUR controller.
read_gen() { kubectl get httproute "${NAME}" -n "${NS}" -o jsonpath='{.metadata.generation}' 2>/dev/null || true; }
read_observed() {
  kubectl get httproute "${NAME}" -n "${NS}" -o json 2>/dev/null \
    | jq -r --arg c "${CONTROLLER}" '
        [.status.parents[]? | select(.controllerName == $c)
         | .conditions[]? | select(.type == "Accepted") | .observedGeneration] | first // empty' 2>/dev/null || true
}
read_accepted() {
  kubectl get httproute "${NAME}" -n "${NS}" -o json 2>/dev/null \
    | jq -r --arg c "${CONTROLLER}" '
        [.status.parents[]? | select(.controllerName == $c)
         | .conditions[]? | select(.type == "Accepted") | .status] | first // empty' 2>/dev/null || true
}

# Waits until OUR controller has observed AT LEAST the given generation.
await_observed() {
  local want="$1" what="$2" elapsed=0 obs acc
  while :; do
    obs=$(read_observed); acc=$(read_accepted)
    case "${obs}" in
      ''|*[!0-9]*) : ;;
      *) [ "${obs}" -ge "${want}" ] && [ -n "${acc}" ] && { echo "${obs}|${acc}"; return 0; } ;;
    esac
    [ "${elapsed}" -lt "${TIMEOUT}" ] || FAIL "the controller never ${what} (generation ${want}) in ${TIMEOUT}s.
  status from '${CONTROLLER}': observedGeneration='${obs:-<none>}' Accepted='${acc:-<none>}'
  A route the controller never wrote a status for is a controller that is NOT
  running. Do NOT take this step: whatever the Gateway's own conditions say,
  they were written by something that is no longer there."
    sleep 3; elapsed=$((elapsed + 3))
  done
}

# ── 1. Creation: it must write a status on an object it has never seen ──
log "creating canary HTTPRoute ${NS}/${NAME}"
apply_canary one
GEN1=$(read_gen)
case "${GEN1}" in ''|*[!0-9]*) FAIL "could not read the canary's generation ('${GEN1}')" ;; esac
RES=$(await_observed "${GEN1}" "acknowledged the new route")
OK "controller wrote status on a BRAND NEW route: observedGeneration=${RES%%|*} Accepted=${RES##*|} (generation ${GEN1})"

# ── 2. Change: generation advances and the controller must FOLLOW it ──
log "changing the canary so its generation advances"
apply_canary two
GEN2=$(read_gen)
case "${GEN2}" in ''|*[!0-9]*) FAIL "could not read the canary's generation after the change" ;; esac
[ "${GEN2}" -gt "${GEN1}" ] || FAIL "the spec change did not advance generation (${GEN1} → ${GEN2});
  this proves nothing about the controller — fix the canary, not the cluster"
RES2=$(await_observed "${GEN2}" "followed the change")
OK "controller FOLLOWED a live change: generation ${GEN1} → ${GEN2}, observedGeneration=${RES2%%|*}"

echo ""
log "=== CONTROLLER PROVEN WORKING — it reconciled a change made just now ==="
echo "  (not 'no error in the log', not 'Programmed says True': observed work.)"
