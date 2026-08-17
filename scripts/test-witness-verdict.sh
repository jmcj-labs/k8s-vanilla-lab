#!/usr/bin/env bash
# NEGATIVE TESTS for the witness verdict — proving it FAILS when it must.
#
# A witness is only worth its verdict if the verdict can say no. These feed
# synthetic series to the same verdict logic the real harness uses and assert
# the outcome, so the guarantee is demonstrated rather than asserted in prose
# (the piece-3 lesson: prove the decision table, do not read it).
#
# No cluster, no network: pure verdict logic.
set -euo pipefail
PASS=0; FAILED=0
run_case() {
  local name="$1" expect="$2" content="$3" gap="${4:-60}"
  local dir; dir=$(mktemp -d)
  printf '%s' "${content}" > "${dir}/series"
  set +e
  SERIES="${dir}/series" LABEL="${name}" STARTED="t0" ENDPOINT="test" \
    WITNESS_MAX_GAP="${gap}" python3 "$(dirname "$0")/lib/witness-verdict.py" >/dev/null 2>&1
  local rc=$?
  set -e
  rm -rf "${dir}"
  local got; [ ${rc} -eq 0 ] && got=PASS || got=FAIL
  if [ "${got}" = "${expect}" ]; then
    echo "  ✓ ${name}: ${got}"; PASS=$((PASS+1))
  else
    echo "  ✗ ${name}: got ${got}, expected ${expect}"; FAILED=$((FAILED+1))
  fi
}

echo "=== veredicto del testigo: casos negativos ==="
run_case "todo-ok"                 PASS "1 00:00:01 http ok
3 00:00:03 http ok
5 00:00:05 http ok"
run_case "un-timeout"              FAIL "1 00:00:01 http ok
3 00:00:03 http timeout
5 00:00:05 http ok"
run_case "un-transporte"           FAIL "1 00:00:01 http ok
3 00:00:03 http transport"
run_case "http-inesperado"         FAIL "1 00:00:01 http ok
3 00:00:03 http http:503"
run_case "grpc-no-OK"              FAIL "1 00:00:01 http ok
3 00:00:03 grpc grpc"
run_case "sonda-no-ejecutable"     FAIL "1 00:00:01 http ok
3 00:00:03 http probe-error:curl-missing"
run_case "codigo-ilegible"         FAIL "1 00:00:01 http ok
3 00:00:03 http probe-error:unparseable-code"
run_case "cert-inesperado"         FAIL "1 00:00:01 http ok
3 00:00:03 http transport:unexpected-cert"
run_case "registro-ilegible"       FAIL "1 00:00:01 http ok
basura"
run_case "cero-sondas"             FAIL ""
run_case "solo-eventos-sin-sondas" FAIL "1 00:00:01 event cert-rotated-expected"
run_case "hueco-en-la-serie"       FAIL "1 00:00:01 http ok
400 00:06:40 http ok" 60
run_case "rotacion-esperada-ok"    PASS "1 00:00:01 http ok
3 00:00:03 event cert-rotated-expected
5 00:00:05 http ok"

# Not a synthetic series but the ABSENCE of one: the window left no record at
# all. It already failed closed via traceback; this asserts it stays that way
# and says why.
set +e
SERIES="$(mktemp -d)/never-written" LABEL="serie-inexistente" STARTED="t0" ENDPOINT="test" \
  python3 "$(dirname "$0")/lib/witness-verdict.py" >/dev/null 2>&1
rc=$?
set -e
if [ ${rc} -ne 0 ]; then
  echo "  ✓ serie-inexistente: FAIL"; PASS=$((PASS+1))
else
  echo "  ✗ serie-inexistente: got PASS, expected FAIL"; FAILED=$((FAILED+1))
fi

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
[ "${FAILED}" -eq 0 ] || exit 1
