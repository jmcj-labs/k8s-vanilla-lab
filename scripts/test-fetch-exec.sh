#!/usr/bin/env bash
# The three routes through the first-boot stub, driven against a FAKE aws on
# PATH -- the real function, not a paraphrase.
#
# INCIDENTS #25 moved the bootstrap scripts out of user_data and into S3. That
# buys headroom and buys a new way to fail: fetching the wrong bytes. The
# middle case below is the one that matters -- a script whose hash does not
# match must NOT run, and the marker file proves it did not.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=bootstrap/fetch-exec.sh
. "$ROOT/bootstrap/fetch-exec.sh"

PASS=0; FAILED=0
log() { echo "[log] $*"; }

# The library bounds every attempt with `timeout`, which Ubuntu 24.04 has and
# the bootstrap already relies on elsewhere. Hosts without coreutils (macOS)
# get a stand-in so the case still runs -- announced, because a shim is not
# the real thing and silence about that would be the lie.
SHIMDIR=$(mktemp -d)
trap 'rm -rf "$SHIMDIR"' EXIT
if ! command -v timeout >/dev/null 2>&1; then
  echo "  nota: 'timeout' ausente en este host; usando sustituto local (en Ubuntu corre el real)"
  cat > "$SHIMDIR/timeout" <<'SHIM'
#!/usr/bin/env bash
secs="$1"; shift
"$@" &
pid=$!
# stdout redirected away: a watcher holding the pipe would block the caller's
# command substitution for the whole sleep.
( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
watcher=$!
wait "$pid" 2>/dev/null
rc=$?
kill "$watcher" 2>/dev/null
if [ "$rc" -ge 128 ]; then rc=124; fi
exit "$rc"
SHIM
  chmod +x "$SHIMDIR/timeout"
  PATH="$SHIMDIR:$PATH"
fi

PAYLOAD='#!/bin/bash
echo "the real script ran"
touch "${MARKER}"
'
GOOD_SHA=$(printf '%s' "$PAYLOAD" | sha256sum | awk '{print $1}')
BAD_SHA="deadbeef00000000000000000000000000000000000000000000000000000000"

# A fake `aws` whose behaviour is driven by a state file.
#   recover : two failures, then it delivers the payload
#   corrupt : delivers the payload at once (checked against a hash that will
#             not match, standing in for bytes that are not what tofu rendered)
#   dead    : never delivers
#   hang    : never returns at all
make_stub() {
  local dir="$1" mode="$2"
  printf '%s\n0\n' "$mode" > "$dir/state"
  printf '%s' "$PAYLOAD" > "$dir/payload"
  cat > "$dir/aws" <<'STUB'
#!/usr/bin/env bash
HERE="$(dirname "$0")"
STATE="$HERE/state"
MODE=$(sed -n 1p "$STATE"); N=$(sed -n 2p "$STATE")
N=$((N + 1)); printf '%s\n%s\n' "$MODE" "$N" > "$STATE"
# aws s3 cp <uri> <dest> --only-show-errors
DEST="$4"
case "$MODE" in
  recover)
    if [ "$N" -le 2 ]; then
      echo "fatal error: An error occurred (404) when calling the HeadObject operation: Not Found" >&2
      exit 1
    fi
    cp "$HERE/payload" "$DEST"
    ;;
  corrupt)
    cp "$HERE/payload" "$DEST"
    ;;
  dead)
    echo "fatal error: Unable to locate credentials" >&2
    exit 1
    ;;
  hang)
    # The CLI that never returns. `exec` on purpose: the process that holds
    # the caller's pipe must BE the one timeout kills, or the command
    # substitution waits on an orphaned child no matter who got signalled.
    exec sleep 300
    ;;
esac
STUB
  chmod +x "$dir/aws"
}

# name | mode | sha | expected rc | max seconds | marker must exist? | needle
run() {
  local name="$1" mode="$2" sha="$3" want_rc="$4" max_s="$5" want_marker="$6" needle="$7"
  local dir; dir=$(mktemp -d); make_stub "$dir" "$mode"
  local marker="$dir/ran" dest="$dir/out/script.sh"
  local t0 t1 out rc
  t0=$(date +%s)
  set +e
  out=$(PATH="$dir:$PATH" MARKER="$marker" fetch_and_exec "s3://bucket/key" "$sha" "$dest" 6 1 2>&1)
  rc=$?
  set -e
  t1=$(date +%s)
  local took=$(( t1 - t0 ))
  local ran=no; [ -f "$marker" ] && ran=yes

  local why=""
  [ "$rc" -eq "$want_rc" ] || why="rc=$rc, want $want_rc"
  [ "$took" -le "$max_s" ] || why="${why:+$why; }tardo ${took}s, limite ${max_s}s"
  [ "$ran" = "$want_marker" ] || why="${why:+$why; }ejecutado=$ran, esperado $want_marker"
  if [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -qF "$needle"; then
    why="${why:+$why; }falta '$needle' en la salida"
  fi
  rm -rf "$dir"
  if [ -z "$why" ]; then
    echo "  OK $name: rc=$rc en ${took}s, ejecutado=$ran"; PASS=$((PASS + 1))
  else
    echo "  FAIL $name: $why"; printf '%s\n' "$out" | sed 's/^/       /'; FAILED=$((FAILED + 1))
  fi
}

echo "=== stub de primer arranque: las tres rutas ==="

# 1. S3 not answering yet is a legitimate transient. Retries, then runs.
run "descarga-se-recupera-y-ejecuta" recover "$GOOD_SHA" 0 5 yes "OK fetched and verified"

# 2. THE ONE THAT MATTERS. The bytes are not the ones tofu rendered, so the
#    script must NOT run. The absent marker is the proof, not the return code.
run "hash-no-coincide-NO-ejecuta" corrupt "$BAD_SHA" 1 3 no "refusing to execute it"

# 3. Never arrives: fails at the deadline, with the captured stderr.
run "nunca-llega-aborta-con-diagnostico" dead "$GOOD_SHA" 1 9 no "Unable to locate credentials"

# 4. THE HUNG CLI. A call that never returns must still abort AT the deadline,
#    not whenever it feels like coming back. The stub sleeps 300s against a 6s
#    budget: only the per-attempt `timeout` can end this.
run "cli-colgada-aborta-al-deadline" hang "$GOOD_SHA" 1 9 no "could not fetch"

echo ""
echo "resultado: $PASS correctos, $FAILED incorrectos"
[ "$FAILED" -eq 0 ] || exit 1
