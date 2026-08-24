#!/usr/bin/env bash
# Does the CLUSTER SCHEMA satisfy what Cilium 1.20.1 REQUIRES?
#
# This is 4a's entry gate, run at the end of 4b so the answer is known before
# the upgrade rather than eighteen seconds after helm says `deployed`.
#
# The list is not from documentation. It is what our own Cilium 1.20.1
# operator printed on 2026-08-23 before refusing to start its Gateway API
# controller — seven kinds, every one at v1:
#
#   requiredGVK=[gateway.networking.k8s.io/v1 Kind=gatewayclasses, gateways,
#                httproutes, grpcroutes, tlsroutes, referencegrants,
#                backendtlspolicies]
#
# EVERY CHECK CARRIES A POSITIVE CONTROL ASSERTION ("expected N, found N").
# Third time this sprint a verification failed silently by finding nothing
# and calling it clean: a grep that matches zero and a state that is absent
# look identical, so the count is asserted, never assumed.
set -euo pipefail

G="gateway.networking.k8s.io"
REQUIRED_KINDS="gatewayclasses gateways httproutes grpcroutes tlsroutes referencegrants backendtlspolicies"
EXPECTED_COUNT=7
REQUIRED_VERSION="${CILIUM_REQUIRED_VERSION:-v1}"

log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || FAIL "kubectl is absent"

log "=== does the schema satisfy Cilium 1.20.1's requiredGVK? ==="

FOUND=0; MISSING=""; UNSERVED=""
for K in ${REQUIRED_KINDS}; do
  # NOT jsonpath '[?(@.served)]': that predicate filters on the FIELD
  # EXISTING, not on its value, so it happily returns versions with
  # served=false. Proven on backendtlspolicies, whose v1alpha3 (served=false)
  # came back as served. A gate that cannot tell true from false is not a
  # gate. jq compares the value explicitly.
  SERVED=$(kubectl get crd "${K}.${G}" -o json 2>/dev/null \
    | jq -r '[.spec.versions[] | select(.served == true) | .name] | join(" ")' || true)
  if [ -z "${SERVED}" ]; then
    echo "  ✗ ${K}: CRD absent or serves nothing" >&2
    MISSING="${MISSING} ${K}"; continue
  fi
  if echo "${SERVED}" | grep -qw "${REQUIRED_VERSION}"; then
    printf "  ✓ %-20s serves %s  (served: %s)\n" "${K}" "${REQUIRED_VERSION}" "${SERVED}"
    FOUND=$((FOUND + 1))
  else
    echo "  ✗ ${K}: does NOT serve ${REQUIRED_VERSION} (serves: ${SERVED})" >&2
    UNSERVED="${UNSERVED} ${K}"
  fi
done

echo ""
echo "  CONTROL ASSERTION: expected ${EXPECTED_COUNT} kinds serving ${REQUIRED_VERSION}, found ${FOUND}"
[ "${FOUND}" -eq "${EXPECTED_COUNT}" ] || FAIL "the schema does NOT satisfy Cilium 1.20.1.
  absent:      ${MISSING:-none}
  not serving ${REQUIRED_VERSION}: ${UNSERVED:-none}
  Starting 4a in this state reproduces 2026-08-23 exactly: the operator logs
  one error, skips its Gateway API controller, and every Envoy that rolls
  afterwards comes up with no listeners, no routes and no TLS secret."

# The overlay's whole purpose: 1.19 must keep working until 1.20 replaces it.
TLS_SERVED=$(kubectl get crd "tlsroutes.${G}" -o json 2>/dev/null \
  | jq -r '[.spec.versions[] | select(.served == true) | .name] | join(" ")' || true)
[ -n "${TLS_SERVED}" ] || FAIL "could not read tlsroutes' served versions at all"
echo "${TLS_SERVED}" | grep -qw v1alpha2 \
  || FAIL "tlsroutes serves ${TLS_SERVED} but NOT v1alpha2 — Cilium 1.19 watches
  v1alpha2 and would go blind to TLSRoute BEFORE 1.20 arrives to use v1.
  That window is the one the hybrid channel exists to close."
echo "  ✓ and v1alpha2 is still served, so 1.19 keeps working until 1.20 lands"

# The dots in an annotation KEY must be escaped in jsonpath, or it reads them
# as nested fields and returns empty — which then looks like "wrong version"
# rather than "broken query". Read it with jq instead: no escaping to get
# wrong, and an empty result is distinguishable from a missing annotation.
BUNDLE=$(kubectl get crd "gateways.${G}" -o json 2>/dev/null \
  | jq -r --arg k "${G}/bundle-version" '.metadata.annotations[$k] // ""' || true)
[ -n "${BUNDLE}" ] || FAIL "could not READ bundle-version at all — the check itself
  failed, which is not the same as the version being wrong"
[ "${BUNDLE}" = "v1.6.1" ] \
  || FAIL "bundle-version is '${BUNDLE}', not the pinned v1.6.1"
echo "  ✓ bundle-version is exactly v1.6.1"

echo ""
log "=== SCHEMA READY FOR 4a ==="
