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
if [ "${1:-}" = api-resources ]; then
  case "$*" in
    *v1alpha2*) echo tlsroutes.gateway.networking.k8s.io ;;
    *v1*) printf '%s\n' backendtlspolicies gatewayclasses gateways grpcroutes httproutes referencegrants tlsroutes \
      | sed 's/$/.gateway.networking.k8s.io/' ;;
    *) exit 2 ;;
  esac
  exit 0
fi
[ "${1:-}" = get ] && [ "${2:-}" = crd ] || exit 2
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
