#!/usr/bin/env bash
# Decision table for the CRD diff conflict detector, executed not read.
# The v1.4.1 rung is case one: schema prose containing the word "conflict"
# must NOT be reported as a conflict.
set -euo pipefail
PASS=0; FAILED=0
detect() {  # → real|none  (mirrors the script's anchored grep)
  local f="$1"
  grep -qE '^Error from server \(Conflict\)' "$f" && { echo real; return; }
  grep -qE '^Error from server' "$f" && { echo other; return; }
  echo none
}
run() {
  local name="$1" expect="$2" body="$3"
  local f; f=$(mktemp); printf '%s\n' "${body}" > "$f"
  local got; got=$(detect "$f"); rm -f "$f"
  if [ "${got}" = "${expect}" ]; then echo "  ✓ ${name}: ${got}"; PASS=$((PASS+1))
  else echo "  ✗ ${name}: got ${got}, expected ${expect}"; FAILED=$((FAILED+1)); fi
}

echo "=== detector de conflictos en diff de CRDs ==="

# THE v1.4.1 FALSE POSITIVES: prose inside the schema.
run "prosa-del-esquema-Conflicted" none '+                  `status: False`, with Reason `Conflicted`.
+                  for conflict resolution and status handling is lacking. Until that can be'
run "prosa-conflict-en-descripcion" none '+      description: Conflicts are resolved by precedence, see conflict rules.'

# The real thing, exactly as the server writes it.
run "conflicto-real" real 'Error from server (Conflict): Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apiextensions.k8s.io/v1: .metadata.annotations.gateway.networking.k8s.io/bundle-version'

# Other server errors must not be silently swallowed as "clean".
run "error-servidor-no-conflicto" other 'Error from server (NotFound): the server could not find the requested resource'
run "error-forbidden" other 'Error from server (Forbidden): customresourcedefinitions.apiextensions.k8s.io is forbidden'

# A clean diff.
run "diff-limpio" none '--- LIVE
+++ MERGED
@@ -8,7 +8,7 @@
-    gateway.networking.k8s.io/bundle-version: v1.4.1
+    gateway.networking.k8s.io/bundle-version: v1.5.1'

# The word at the start of a line but not a server error line.
run "linea-que-empieza-por-conflict" none 'conflict resolution is described below'

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
