#!/usr/bin/env bash
# Does the CLUSTER SCHEMA satisfy what Cilium 1.20.1 REQUIRES?
#
# This is both the direct-bootstrap smoke gate and the archived 4a entry gate.
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
# At the pinned final rung TLSRoute serves EXACTLY these three versions. Check
# the count as a positive control, then every name: an empty/broken jq cannot
# pass, and neither can an unexpected fourth version.
EXPECTED_TLS_COUNT=3
EXPECTED_TLS_VERSIONS="v1 v1alpha2 v1alpha3"
TLS_GATE=$(kubectl get crd "tlsroutes.${G}" -o json 2>/dev/null \
  | jq -r '([.spec.versions[] | select(.served == true) | .name] | sort) as $v
      | "\($v | length)|\($v | join(" "))"' || true)
[ -n "${TLS_GATE}" ] || FAIL "could not read tlsroutes' served versions at all"
TLS_COUNT=${TLS_GATE%%|*}
TLS_SERVED=${TLS_GATE#*|}
case "${TLS_COUNT}" in ''|*[!0-9]*) FAIL "tlsroutes served-version count is unreadable: '${TLS_COUNT}'" ;; esac
echo "  CONTROL ASSERTION: expected ${EXPECTED_TLS_COUNT} TLSRoute versions, found ${TLS_COUNT} (${TLS_SERVED})"
[ "${TLS_COUNT}" -eq "${EXPECTED_TLS_COUNT}" ] \
  || FAIL "tlsroutes serves ${TLS_COUNT} versions (${TLS_SERVED}), expected exactly ${EXPECTED_TLS_COUNT}"
for V in ${EXPECTED_TLS_VERSIONS}; do
  echo "${TLS_SERVED}" | grep -qw "${V}" \
    || FAIL "tlsroutes serves ${TLS_SERVED} but NOT ${V}"
done
echo "  ✓ tlsroutes serves exactly v1 + v1alpha2 + v1alpha3"

# The dots in an annotation KEY must be escaped in jsonpath, or it reads them
# as nested fields and returns empty — which then looks like "wrong version"
# rather than "broken query". Read it with jq instead: no escaping to get
# wrong, and an empty result is distinguishable from a missing annotation.
BUNDLE_FOUND=0
for K in ${REQUIRED_KINDS}; do
  BUNDLE=$(kubectl get crd "${K}.${G}" -o json 2>/dev/null \
    | jq -r --arg k "${G}/bundle-version" '.metadata.annotations[$k] // ""' || true)
  [ -n "${BUNDLE}" ] || FAIL "could not READ bundle-version on ${K} at all — the
  check itself failed, which is not the same as the version being wrong"
  [ "${BUNDLE}" = "v1.6.1" ] \
    || FAIL "${K} bundle-version is '${BUNDLE}', not the pinned v1.6.1"
  BUNDLE_FOUND=$((BUNDLE_FOUND + 1))
done
echo "  CONTROL ASSERTION: expected ${EXPECTED_COUNT} CRDs at bundle v1.6.1, found ${BUNDLE_FOUND}"
[ "${BUNDLE_FOUND}" -eq "${EXPECTED_COUNT}" ] \
  || FAIL "bundle-version control count failed: expected ${EXPECTED_COUNT}, found ${BUNDLE_FOUND}"
echo "  ✓ bundle-version is exactly v1.6.1 on all seven CRDs"

# API discovery is the serving fact. A CRD spec can claim served=true while
# the API resource is not yet established/discoverable; that state is not a
# usable bootstrap result.
EXPECTED_V1=$(printf '%s\n' ${REQUIRED_KINDS} | sed "s|$|.${G}|" | sort)
SERVED_V1=$(kubectl get --raw "/apis/${G}/v1" \
  | jq -r --arg g "${G}" \
      '.resources[] | select(.name | contains("/") | not) | (.name + "." + $g)' \
  | sort) \
  || FAIL "API discovery failed for ${G}/v1"
[ "${SERVED_V1}" = "${EXPECTED_V1}" ] \
  || FAIL "API discovery does not expose the exact seven ${G}/v1 resources"
SERVED_ALPHA2=$(kubectl get --raw "/apis/${G}/v1alpha2" \
  | jq -r --arg g "${G}" \
      '.resources[] | select(.name | contains("/") | not) | (.name + "." + $g)' \
  | sort) \
  || FAIL "API discovery failed for ${G}/v1alpha2"
[ "${SERVED_ALPHA2}" = "tlsroutes.${G}" ] \
  || FAIL "API discovery v1alpha2 is '${SERVED_ALPHA2}', expected only tlsroutes.${G}"
echo "  ✓ API discovery serves exact v1 set + TLSRoute v1alpha2"

echo ""
log "=== SCHEMA READY FOR CILIUM 1.20.1 ==="
