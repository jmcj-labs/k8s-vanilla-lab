#!/usr/bin/env bash
# QUIS CUSTODIET — negative tests for the watchdog itself.
#
# scripts/test-witness-verdict.sh proves the VERDICT can say no. This proves
# the thing that decides whether a verdict may be computed at all can say no
# too, because the first version of it could not:
#
#   liveness was `kill -0 <pid>` — "does a process with this number exist",
#   not "was my loop still working". It answers YES for a PID the OS recycled
#   onto an unrelated process, and YES for a loop wedged and probing nothing.
#
# That is the watchdog inheriting the exact bug it was added to catch. So the
# cases below drive `witness-traffic.sh stop` against hand-built state dirs
# and assert the outcome — including killing the VERIFIER itself.
#
# No cluster, no network: cmd_stop never resolves an endpoint.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WITNESS="${HERE}/witness-traffic.sh"
PASS=0; FAILED=0

# A clean two-probe series whose timestamps are recent and adjacent, so the
# only thing under test is the liveness gate.
make_state() {
  local dir="$1" hb_age="$2"; local now; now=$(date -u +%s)
  mkdir -p "${dir}"
  printf '%s 00:00:01 http ok\n%s 00:00:03 http ok\n' "$((now - 4))" "$((now - 2))" > "${dir}/series"
  echo "quis-custodiet" > "${dir}/label"
  echo "2026-08-17T00:00:00Z" > "${dir}/started"
  echo "test-endpoint" > "${dir}/endpoint"
  [ "${hb_age}" = "none" ] || echo "$((now - hb_age))" > "${dir}/heartbeat"
}

# Something alive to point a pid file at, standing in for the PID the OS
# handed to an unrelated process after our loop died.
# stdout/stderr redirected away from the command substitution: $(spawn_decoy)
# waits for every child holding the pipe open, so a bare `sleep 120 &` blocks
# the caller for the full two minutes.
spawn_decoy() { sleep 120 >/dev/null 2>&1 & echo $!; }

check() {
  local name="$1" expect="$2" dir="$3" extra_path="${4:-}"
  set +e
  if [ -n "${extra_path}" ]; then
    PATH="${extra_path}:${PATH}" WITNESS_STATE_DIR="${dir}" bash "${WITNESS}" stop >/dev/null 2>&1
  else
    WITNESS_STATE_DIR="${dir}" bash "${WITNESS}" stop >/dev/null 2>&1
  fi
  local rc=$?
  set -e
  local got; [ ${rc} -eq 0 ] && got=PASS || got=FAIL
  if [ "${got}" = "${expect}" ]; then
    echo "  ✓ ${name}: ${got}"; PASS=$((PASS+1))
  else
    echo "  ✗ ${name}: got ${got}, expected ${expect}"; FAILED=$((FAILED+1))
  fi
}

echo "=== quis custodiet: el watchdog del testigo ==="

# CONTROL. A live loop with a fresh heartbeat must still pass, or the gate is
# just "always fail" and proves nothing.
D=$(mktemp -d); make_state "${D}" 1; PID=$(spawn_decoy); echo "${PID}" > "${D}/pid"
check "latido-fresco" PASS "${D}"; kill "${PID}" 2>/dev/null || true; rm -rf "${D}"

# THE CASE THE OLD CHECK GOT WRONG: the loop is long dead, but its PID now
# belongs to some other live process. `kill -0` said "alive" and the window
# passed. The heartbeat is not fooled.
D=$(mktemp -d); make_state "${D}" 600; PID=$(spawn_decoy); echo "${PID}" > "${D}/pid"
check "pid-reciclado-por-otro-proceso" FAIL "${D}"; kill "${PID}" 2>/dev/null || true; rm -rf "${D}"

# A loop that exists but stopped working — alive by PID, witnessing nothing.
D=$(mktemp -d); make_state "${D}" 300; PID=$(spawn_decoy); echo "${PID}" > "${D}/pid"
check "bucle-atascado" FAIL "${D}"; kill "${PID}" 2>/dev/null || true; rm -rf "${D}"

# Loop killed outright: no live PID, stale heartbeat.
D=$(mktemp -d); make_state "${D}" 300; PID=$(spawn_decoy); kill "${PID}" 2>/dev/null || true
wait "${PID}" 2>/dev/null || true; echo "${PID}" > "${D}/pid"
check "bucle-muerto" FAIL "${D}"; rm -rf "${D}"

# Never completed one iteration: no heartbeat at all.
D=$(mktemp -d); make_state "${D}" none; PID=$(spawn_decoy); echo "${PID}" > "${D}/pid"
check "sin-latido" FAIL "${D}"; kill "${PID}" 2>/dev/null || true; rm -rf "${D}"

# The record of whether it was alive is itself damaged — that is not "alive".
D=$(mktemp -d); make_state "${D}" 1; echo "basura" > "${D}/heartbeat"
PID=$(spawn_decoy); echo "${PID}" > "${D}/pid"
check "latido-ilegible" FAIL "${D}"; kill "${PID}" 2>/dev/null || true; rm -rf "${D}"

# THE VERIFIER DIES MID-VERDICT. A stub python3 that SIGKILLs itself: no
# verdict was produced, so the window has NOT passed.
D=$(mktemp -d); make_state "${D}" 1; PID=$(spawn_decoy); echo "${PID}" > "${D}/pid"
STUB=$(mktemp -d); printf '#!/bin/sh\nkill -9 $$\n' > "${STUB}/python3"; chmod +x "${STUB}/python3"
check "verificador-muerto-a-mitad" FAIL "${D}" "${STUB}"
kill "${PID}" 2>/dev/null || true; rm -rf "${D}" "${STUB}"

# The verifier cannot run at all. "I could not compute the verdict" is not
# "the window passed" (INCIDENTS #17, in the last place it could still hide).
D=$(mktemp -d); make_state "${D}" 1; PID=$(spawn_decoy); echo "${PID}" > "${D}/pid"
EMPTY=$(mktemp -d)
set +e
WITNESS_STATE_DIR="${D}" PATH="${EMPTY}" bash "${WITNESS}" stop >/dev/null 2>&1
RC=$?
set -e
if [ ${RC} -ne 0 ]; then
  echo "  ✓ sin-verificador: FAIL"; PASS=$((PASS+1))
else
  echo "  ✗ sin-verificador: got PASS, expected FAIL"; FAILED=$((FAILED+1))
fi
kill "${PID}" 2>/dev/null || true; rm -rf "${D}" "${EMPTY}"

# The series exists but cannot be read. Skipped rather than faked when the
# test runs as root, where chmod does not deny — a case we cannot set up is
# not a case that passed.
D=$(mktemp -d); make_state "${D}" 1; PID=$(spawn_decoy); echo "${PID}" > "${D}/pid"
chmod 000 "${D}/series"
if [ -r "${D}/series" ]; then
  echo "  ⚠ serie-ilegible: OMITIDO (corriendo como root: chmod no deniega)"
else
  check "serie-ilegible" FAIL "${D}"
fi
chmod 644 "${D}/series"; kill "${PID}" 2>/dev/null || true; rm -rf "${D}"

# No window open at all.
D=$(mktemp -d)
check "sin-ventana-abierta" FAIL "${D}"; rm -rf "${D}"

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
