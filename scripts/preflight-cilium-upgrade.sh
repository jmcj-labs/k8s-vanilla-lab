#!/usr/bin/env bash
# PRE-FLIGHT for the Cilium upgrade (4a) — Cilium's own pre-flight DaemonSet,
# driven fail-closed.
#
# What it actually buys us, and why it runs BEFORE the witness window closes
# on a broken cluster:
#   - it pulls the target images onto EVERY node while the current version is
#     still serving, so the real upgrade is not a rolling image pull
#   - it validates the existing CiliumNetworkPolicies against the NEW parser,
#     which is where a policy that no longer parses would otherwise surface:
#     mid-rollout, with the datapath already half-migrated
#
# THE RULE THIS FILE OBEYS (INCIDENTS #17): a check that cannot determine
# something FAILS. A timeout is not a pass, an unreadable count is not a
# pass, and "the DaemonSet is not there yet" is not "it is ready".
set -euo pipefail

TARGET="${1:-}"
NAMESPACE="${CILIUM_NAMESPACE:-kube-system}"
RELEASE="${CILIUM_RELEASE:-cilium}"
PREFLIGHT="${CILIUM_PREFLIGHT_RELEASE:-cilium-preflight}"
TIMEOUT="${PREFLIGHT_TIMEOUT:-300}"
OUT="${PREFLIGHT_OUT:-/tmp/cilium-live-values.yaml}"

log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
OK()   { echo "  ✓ $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }

[ -n "${TARGET}" ] || FAIL "usage: $0 <target-version>   e.g. $0 1.20.1"
command -v helm    >/dev/null 2>&1 || FAIL "helm is absent"
command -v kubectl >/dev/null 2>&1 || FAIL "kubectl is absent"

log "=== Cilium upgrade pre-flight → ${TARGET} ==="

# 1. The live values, captured from the cluster rather than retyped. This file
#    IS the upgrade input: --reuse-values is deliberately NOT used, because
#    across a minor it also suppresses the new chart's defaults.
helm get values "${RELEASE}" -n "${NAMESPACE}" -o yaml > "${OUT}" \
  || FAIL "cannot read the live Helm values for ${RELEASE}/${NAMESPACE}"
[ -s "${OUT}" ] || FAIL "the live values came back EMPTY — refusing to upgrade
  from a values file we could not read"
OK "live values captured → ${OUT} ($(wc -l < "${OUT}" | tr -d ' ') lines)"

# 2. The values that carry pieces 2 and 3. If any is missing here it is
#    already missing from the cluster, and the upgrade would not be what
#    silently dropped it — but we would have no way to tell afterwards.
MISSING=0
for KEY in kubeProxyReplacement k8sServiceHost k8sServicePort; do
  grep -qE "^\s*${KEY}:" "${OUT}" || { echo "  ✗ missing value: ${KEY}" >&2; MISSING=$((MISSING + 1)); }
done
grep -qE "^\s*enabled: true" "${OUT}" || true   # gatewayAPI/hubble are nested; checked below
for PATH_KEY in gatewayAPI hubble ipam; do
  grep -qE "^${PATH_KEY}:" "${OUT}" || { echo "  ✗ missing block: ${PATH_KEY}" >&2; MISSING=$((MISSING + 1)); }
done
[ "${MISSING}" -eq 0 ] || FAIL "${MISSING} critical value(s) absent from the live release.
  Fix the running install BEFORE upgrading — an upgrade cannot restore what
  was already gone, and afterwards nobody could tell which step lost it."
OK "critical values present: strict KPR, NLB endpoint, Gateway API, Hubble, IPAM"

K8S_HOST=$(grep -E "^\s*k8sServiceHost:" "${OUT}" | head -1 | awk '{print $2}' | tr -d '"')
case "${K8S_HOST}" in
  *.elb.*|*.amazonaws.com) OK "k8sServiceHost is the NLB endpoint (${K8S_HOST})" ;;
  "")  FAIL "k8sServiceHost is empty" ;;
  *[0-9].[0-9]*.[0-9]*.[0-9]*) FAIL "k8sServiceHost is an IP (${K8S_HOST}) — ADR-007 forbids
  anchoring the agents to a node address. Refusing to carry that into 1.20." ;;
  *) OK "k8sServiceHost = ${K8S_HOST}" ;;
esac

# 3. How many nodes must the pre-flight land on. Read once, from the cluster.
NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
case "${NODES}" in
  ''|*[!0-9]*|0) FAIL "could not count cluster nodes — cannot tell what 'all nodes' means" ;;
esac
OK "cluster has ${NODES} nodes; the pre-flight must be ready on all of them"

# 4. The pre-flight DaemonSet itself: agent and operator off, preflight on.
log "installing the pre-flight DaemonSet (${TARGET})"
helm install "${PREFLIGHT}" cilium/cilium --version "${TARGET}" \
  --namespace "${NAMESPACE}" \
  --set preflight.enabled=true \
  --set agent=false \
  --set operator.enabled=false \
  --set-string k8sServiceHost="${K8S_HOST}" \
  --set k8sServicePort=6443 >/dev/null \
  || FAIL "the pre-flight release failed to install"

cleanup() {
  log "removing the pre-flight release"
  helm uninstall "${PREFLIGHT}" -n "${NAMESPACE}" >/dev/null 2>&1 \
    || echo "  ⚠ could not uninstall ${PREFLIGHT} — remove it by hand before upgrading" >&2
}
trap cleanup EXIT

# 5. Wait for READY == DESIRED, and TIME OUT INTO A FAILURE.
log "waiting for the pre-flight to be ready on all ${NODES} nodes (timeout ${TIMEOUT}s)"
DS="cilium-pre-flight-check"
ELAPSED=0
while :; do
  READY=$(kubectl -n "${NAMESPACE}" get ds "${DS}" \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
  DESIRED=$(kubectl -n "${NAMESPACE}" get ds "${DS}" \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)
  case "${READY}${DESIRED}" in
    ''|*[!0-9]*) : ;;                       # not readable yet: keep waiting, never pass
    *) [ "${READY}" = "${DESIRED}" ] && [ "${READY}" = "${NODES}" ] && break ;;
  esac
  [ "${ELAPSED}" -lt "${TIMEOUT}" ] || FAIL "the pre-flight did NOT become ready in ${TIMEOUT}s
  (ready='${READY}' desired='${DESIRED}' nodes=${NODES}). A pre-flight that did
  not finish is not a pre-flight that passed — do NOT start the upgrade.
  Look at: kubectl -n ${NAMESPACE} describe ds ${DS}"
  sleep 5; ELAPSED=$((ELAPSED + 5))
done
OK "pre-flight ready on ${READY}/${NODES} nodes in ${ELAPSED}s — target images pulled everywhere"

# 6. CNP validation. The pre-flight pod reports whether every existing policy
#    still parses under the new version.
log "checking the policy validation result"
VALIDATION=$(kubectl -n "${NAMESPACE}" logs -l k8s-app=cilium-pre-flight-check \
  -c clean-cilium-state --tail=-1 2>/dev/null || true)
DEPRECATED=$(printf '%s' "${VALIDATION}" | grep -icE "deprecated|cannot be converted|error" || true)
if [ "${DEPRECATED}" != "0" ]; then
  echo "${VALIDATION}" | grep -iE "deprecated|cannot be converted|error" | head -10 >&2
  FAIL "the pre-flight reported policy problems — resolve them before upgrading"
fi
OK "no policy conversion problems reported"

echo ""
log "=== PRE-FLIGHT PASSED — the upgrade may proceed ==="
cat <<EOF

Next, with the witness already open:

  helm upgrade ${RELEASE} cilium/cilium --version ${TARGET} \\
    --namespace ${NAMESPACE} -f ${OUT} --wait --timeout 10m

The -f is the live values file captured above, NOT --reuse-values: across a
minor, reuse-values would also suppress the new chart's defaults.
EOF
