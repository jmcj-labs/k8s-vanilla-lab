#!/usr/bin/env bash
# Executable decision table for 4a's schema entry gate. A green row proves
# the positive path exists; each negative row breaks exactly one assertion.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
REAL_PATH=${PATH}
PASS=0
FAILED=0

cat > "${TMP}/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 3 ] && [ "$1" = get ] && [ "$2" = --raw ]; then
  case "$3" in
    /apis/gateway.networking.k8s.io/v1alpha2)
      printf '%s\n' '{"resources":[{"name":"tlsroutes"},{"name":"tlsroutes/status"}]}' ;;
    /apis/gateway.networking.k8s.io/v1)
      printf '%s\n' '{"resources":[{"name":"backendtlspolicies"},{"name":"backendtlspolicies/status"},{"name":"gatewayclasses"},{"name":"gatewayclasses/status"},{"name":"gateways"},{"name":"gateways/status"},{"name":"grpcroutes"},{"name":"grpcroutes/status"},{"name":"httproutes"},{"name":"httproutes/status"},{"name":"referencegrants"},{"name":"tlsroutes"},{"name":"tlsroutes/status"}]}' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
[ "$#" -eq 5 ] && [ "$1" = get ] && [ "$2" = crd ] && [ "$4" = -o ] && [ "$5" = json ] || exit 1
case "$3" in
  gatewayclasses.gateway.networking.k8s.io|gateways.gateway.networking.k8s.io|httproutes.gateway.networking.k8s.io|grpcroutes.gateway.networking.k8s.io|tlsroutes.gateway.networking.k8s.io|referencegrants.gateway.networking.k8s.io|backendtlspolicies.gateway.networking.k8s.io) ;;
  *) exit 1 ;;
esac
KIND=${3%%.*}
VERSIONS='[{"name":"v1","served":true}]'
if [ "${KIND}" = tlsroutes ]; then
  case "${SCENARIO:-happy}" in
    missing-alpha3) VERSIONS='[{"name":"v1","served":true},{"name":"v1alpha2","served":true},{"name":"v1alpha3","served":false}]' ;;
    extra-version)  VERSIONS='[{"name":"v1","served":true},{"name":"v1alpha2","served":true},{"name":"v1alpha3","served":true},{"name":"v2","served":true}]' ;;
    *)              VERSIONS='[{"name":"v1","served":true},{"name":"v1alpha2","served":true},{"name":"v1alpha3","served":true}]' ;;
  esac
fi
BUNDLE=v1.6.1
[ "${SCENARIO:-happy}" = wrong-one-bundle ] && [ "${KIND}" = grpcroutes ] && BUNDLE=v1.6.0
printf '{"metadata":{"annotations":{"gateway.networking.k8s.io/bundle-version":"%s"}},"spec":{"versions":%s}}\n' \
  "${BUNDLE}" "${VERSIONS}"
MOCK
chmod +x "${TMP}/kubectl"

# The command that caused INCIDENTS #22 must be impossible in the stub just
# as it is in real kubectl. A permissive mock would recreate the false green.
set +e
"${TMP}/kubectl" api-resources --cached=false \
  --api-version=gateway.networking.k8s.io/v1 -o name >/dev/null 2>&1
STUB_REJECT_RC=$?
set -e
[ "${STUB_REJECT_RC}" -eq 1 ] || {
  echo "stub accepted the impossible api-resources --api-version call (rc=${STUB_REJECT_RC})" >&2
  exit 1
}

run() {
  local name=$1 scenario=$2 expected=$3 rc
  set +e
  PATH="${TMP}:${REAL_PATH}" SCENARIO="${scenario}" \
    bash "${ROOT}/scripts/verify-cilium-120-schema.sh" >/dev/null 2>&1
  rc=$?
  set -e
  if { [ "${expected}" = pass ] && [ "${rc}" -eq 0 ]; } ||
     { [ "${expected}" = fail ] && [ "${rc}" -ne 0 ]; }; then
    echo "  ✓ ${name}: ${expected}"
    PASS=$((PASS + 1))
  else
    echo "  ✗ ${name}: rc=${rc}, expected ${expected}"
    FAILED=$((FAILED + 1))
  fi
}

echo "=== gate de esquema Cilium 1.20: tabla de decisión ==="
run "control-siete-crds-tres-tls-bundle-exacto" happy pass
run "falta-v1alpha3-servida" missing-alpha3 fail
run "version-tls-inesperada" extra-version fail
run "un-crd-con-bundle-incorrecto" wrong-one-bundle fail

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ]
