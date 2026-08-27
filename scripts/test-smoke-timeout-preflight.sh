#!/usr/bin/env bash
# Resolution of the GNU timeout binary, driven against the REAL script with a
# trimmed PATH -- the actual decision, not a paraphrase of it.
#
# Why this exists: macOS ships no `timeout`, and without it the two NLB polls
# spin until their 300s deadline and then blame the infrastructure ("NLB
# targets not ALL healthy") for a tool that was never there. A missing tool
# must not be reported as a sick cluster, so the check now fails fast, before
# any external dependency and before any temporary resource is created.
#
# The gtimeout case is not decoration: `brew install coreutils` installs the
# GNU tools g-prefixed so they do not shadow the system ones, so "only
# gtimeout" is the ordinary state of a Homebrew macOS, not an edge case.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SMOKE="${ROOT}/scripts/smoke-test.sh"
PASS=0; FAILED=0

NEEDLE="GNU timeout is required"
MARKER="REACHED-EXTERNAL-DEPENDENCY"
# PATH is the temp dir and NOTHING else. An earlier version kept /usr/bin:/bin
# as a base "verified clean" -- verified on macOS, where timeout does not
# exist. Ubuntu ships /usr/bin/timeout, so on CI the "neither present" case
# silently had one and the test reported green for the wrong reason. A base
# checked on one platform is not a clean base; it is a local observation.
#
# Only the tested script runs under this PATH: it needs no external process
# before the preflight, which is the contract under test.

# Runs the REAL script with the given fake binaries prepended to that base.
# The kubectl stub prints a marker: reaching it is POSITIVE proof the preflight
# was passed. Absence of the error message alone would not be -- the script
# could have died earlier and never reached the decision at all.
run_case() {
  local name="$1" want_needle="$2" want_marker="$3"
  shift 3
  local dir b
  dir=$(mktemp -d)
  for b in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "${dir}/${b}"; chmod +x "${dir}/${b}"
  done
  printf '#!/bin/sh\necho "%s"\nexit 1\n' "${MARKER}" > "${dir}/kubectl"
  chmod +x "${dir}/kubectl"

  local out
  set +e
  out=$(PATH="${dir}" /bin/bash "${SMOKE}" 2>&1)
  set -e
  rm -rf "${dir}"

  local needle=no marker=no why=""
  printf '%s\n' "${out}" | grep -qF "${NEEDLE}" && needle=yes
  printf '%s\n' "${out}" | grep -qF "${MARKER}" && marker=yes
  [ "${needle}" = "${want_needle}" ] || why="mensaje de timeout=${needle}, esperado ${want_needle}"
  [ "${marker}" = "${want_marker}" ] || why="${why:+${why}; }llego a la dependencia externa=${marker}, esperado ${want_marker}"

  if [ -z "${why}" ]; then
    echo "  OK ${name}: timeout-msg=${needle} alcanzo-externa=${marker}"; PASS=$((PASS + 1))
  else
    echo "  FAIL ${name}: ${why}"; printf '%s\n' "${out}" | sed 's/^/       /'; FAILED=$((FAILED + 1))
  fi
}

echo "=== resolucion del binario timeout: los tres casos ==="

# 1. The GNU name is there: selected, and the run gets past the preflight.
run_case "timeout-presente"       no  yes timeout

# 2. Only the Homebrew-prefixed name. Without the elif this would abort, so
#    reaching the external dependency IS the proof the fallback was taken.
run_case "solo-gtimeout-fallback" no  yes gtimeout

# 3. Neither: aborts with the diagnosis and NEVER reaches an external
#    dependency -- fail-fast, before any temporary resource exists.
run_case "ninguno-falla-rapido"   yes no

echo ""
echo "=== el diagnostico nombra el remedio ==="
D=$(mktemp -d)
printf '#!/bin/sh\necho "%s"\nexit 1\n' "${MARKER}" > "${D}/kubectl"; chmod +x "${D}/kubectl"
set +e
OUT=$(PATH="${D}" /bin/bash "${SMOKE}" 2>&1)
set -e
rm -rf "${D}"
if printf '%s\n' "${OUT}" | grep -qF "brew install coreutils"; then
  echo "  OK el mensaje dice como arreglarlo"; PASS=$((PASS + 1))
else
  echo "  FAIL el mensaje no menciona 'brew install coreutils'"; FAILED=$((FAILED + 1))
fi

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
