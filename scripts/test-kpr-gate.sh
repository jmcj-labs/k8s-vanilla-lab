#!/usr/bin/env bash
# The three routes through the live-datapath gate, driven against a FAKE
# kubectl on PATH -- the real loop, not a paraphrase of it.
#
# INCIDENTS #24: the previous form was `KPR=$(kubectl ... 2>/dev/null | awk)`.
# Under `set -euo pipefail` a failing exec was swallowed and killed the founder
# before its own guard could log a word. These cases exist so that each of the
# three outcomes is observable, with the diagnosis intact.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=bootstrap/kpr-gate.sh
. "$ROOT/bootstrap/kpr-gate.sh"

PASS=0; FAILED=0
log() { echo "[log] $*"; }

# A fake kubectl whose behaviour is driven by a state file.
#   recover : rc!=0 twice, then the real captured line
#   false   : answers at once with a genuine False
#   dead    : never answers
make_stub() {
  local dir="$1" mode="$2"
  printf '%s\n0\n' "${mode}" > "${dir}/state"
  cat > "${dir}/kubectl" <<'STUB'
#!/usr/bin/env bash
STATE="$(dirname "$0")/state"
MODE=$(sed -n 1p "${STATE}"); N=$(sed -n 2p "${STATE}")
N=$((N + 1)); printf '%s\n%s\n' "${MODE}" "${N}" > "${STATE}"
case "${MODE}" in
  recover)
    if [ "${N}" -le 2 ]; then
      echo "error: unable to upgrade connection: container not found (\"cilium-agent\")" >&2
      exit 1
    fi
    echo "KubeProxyReplacement:    True   [ens5   10.0.1.37 fe80::4a0:a3ff:fe0a:950f (Direct Routing)]"
    ;;
  false)
    echo "KubeProxyReplacement:  False"
    ;;
  dead)
    echo "error: unable to upgrade connection: pod does not exist" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "${dir}/kubectl"
}

# name | mode | expected rc | max seconds it may take | text required in output
run() {
  local name="$1" mode="$2" want_rc="$3" max_s="$4" needle="$5"
  local dir; dir=$(mktemp -d); make_stub "${dir}" "${mode}"
  local t0 t1 out rc
  t0=$(date +%s)
  set +e
  out=$(PATH="${dir}:${PATH}" kpr_gate 6 1 2>&1)
  rc=$?
  set -e
  t1=$(date +%s)
  local took=$(( t1 - t0 ))
  rm -rf "${dir}"

  local why=""
  [ "${rc}" -eq "${want_rc}" ] || why="rc=${rc}, want ${want_rc}"
  [ "${took}" -le "${max_s}" ] || why="${why:+${why}; }tardo ${took}s, limite ${max_s}s"
  if [ -n "${needle}" ] && ! printf '%s\n' "${out}" | grep -qF "${needle}"; then
    why="${why:+${why}; }falta '${needle}' en la salida"
  fi
  if [ -z "${why}" ]; then
    echo "  OK ${name}: rc=${rc} en ${took}s"; PASS=$((PASS + 1))
  else
    echo "  FAIL ${name}: ${why}"; printf '%s\n' "${out}" | sed 's/^/       /'; FAILED=$((FAILED + 1))
  fi
}

echo "=== gate del datapath vivo: las tres rutas ==="

# 1. The agent is still starting: rc!=0, then it answers True. The whole point
#    of #24 -- this must PASS, and without burning the deadline.
run "arranca-tarde-y-luego-contesta-True" recover 0 5 "OK live datapath answered KubeProxyReplacement=True after"

# 2. It answers False. A real verdict; waiting cannot mend it, so it must fail
#    AT ONCE -- well inside the deadline -- with the line in the log.
run "contesta-False-falla-sin-reintentar" false 1 2 "KubeProxyReplacement='False'"

# 3. It never answers. Must fail at the deadline WITH the captured stderr,
#    which is exactly what 2>/dev/null destroyed in #24.
run "nunca-contesta-falla-con-el-stderr" dead 1 9 "unable to upgrade connection"

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
