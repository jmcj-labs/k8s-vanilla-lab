#!/usr/bin/env bash
# Decision table for the KubeProxyReplacement token parser, executed not read.
#
# INCIDENTS #23: `awk -F:` truncated the value at the first colon inside the
# device list's IPv6 address, so the founder aborted at Step 5/9 on a datapath
# that was in fact correct. The fix reads the token positionally.
#
# The fixtures below are REAL cilium-dbg output captured from the live CP-0 of
# run 89558194852 (forensics_89558194852/11-parser-nuevo-validado.txt), not
# prose written from memory. A parser test fed invented lines proves only that
# the parser agrees with the imagination of whoever wrote it.
set -euo pipefail
PASS=0; FAILED=0

# THE REAL LINE, byte for byte as the agent printed it.
REAL='KubeProxyReplacement:    True   [ens5   10.0.1.227 fe80::4a6:16ff:fea6:6065 (Direct Routing)]'
# Same node without an IPv6 link-local: the device suffix is still there.
NO_V6='KubeProxyReplacement:    True   [ens5   10.0.1.227 (Direct Routing)]'
# A datapath that is genuinely not replacing kube-proxy.
FALSE_LINE='KubeProxyReplacement:  False'

# The parser as it now appears in bootstrap/control-plane.yaml and
# scripts/smoke-test.sh. Kept character-identical on purpose.
kpr() { awk '$1 == "KubeProxyReplacement:" {print $2; exit}'; }
# The parser that shipped in b9adbaa and aborted the founder.
kpr_broken() {
  awk -F: 'tolower($1) ~ /kubeproxyreplacement/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}'
}

run() {  # name expected(accept|reject) line
  local name="$1" expect="$2" line="$3" got verdict
  got=$(printf '%s\n' "${line}" | kpr)
  [ "${got}" = "True" ] && verdict=accept || verdict=reject
  if [ "${verdict}" = "${expect}" ]; then
    echo "  OK ${name}: ${verdict} (token='${got}')"; PASS=$((PASS+1))
  else
    echo "  FAIL ${name}: ${verdict} (token='${got}'), expected ${expect}"; FAILED=$((FAILED+1))
  fi
}

echo "=== parser del token KubeProxyReplacement ==="
run "linea-real-capturada-con-ipv6"  accept "${REAL}"
run "misma-linea-sin-ipv6"           accept "${NO_V6}"
run "datapath-en-False"              reject "${FALSE_LINE}"

echo ""
echo "=== controles: los defectos que este test existe para atrapar ==="

# CONTROL 1. The broken parser must FAIL the real line. Without this the suite
# would pass whether or not the fix is present, and prove nothing.
BROKEN_TOKEN=$(printf '%s\n' "${REAL}" | kpr_broken)
if [ "${BROKEN_TOKEN}" != "True" ]; then
  echo "  OK parser-roto-suspende-la-linea-real (extrajo '${BROKEN_TOKEN}')"; PASS=$((PASS+1))
else
  echo "  FAIL parser-roto-aceptó la línea real: el test no discrimina"; FAILED=$((FAILED+1))
fi

# CONTROL 2. The mirror defect from scripts/smoke-test.sh. This line is
# CONSTRUCTED, not captured: it shows what `grep -q "True"` would wave through.
SUBSTRING_TRAP='KubeProxyReplacement:  False  [ens5   10.0.1.227 (Direct Routing, TrueNAS-bridge)]'
if printf '%s\n' "${SUBSTRING_TRAP}" | grep -q "True"; then
  TOKEN=$(printf '%s\n' "${SUBSTRING_TRAP}" | kpr)
  if [ "${TOKEN}" != "True" ]; then
    echo "  OK grep-por-subcadena-aceptaba-un-False-que-el-token-rechaza (token='${TOKEN}')"; PASS=$((PASS+1))
  else
    echo "  FAIL el parser nuevo también acepta el False"; FAILED=$((FAILED+1))
  fi
else
  echo "  FAIL la trampa de subcadena no reproduce el defecto"; FAILED=$((FAILED+1))
fi

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
