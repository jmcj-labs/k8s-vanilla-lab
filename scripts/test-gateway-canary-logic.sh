#!/usr/bin/env bash
# Decision table for the Gateway API controller canary, executed rather than
# read (the piece-3 lesson). No cluster: synthetic HTTPRoute status objects
# fed to the same jq the real script uses.
#
# What must hold: the canary accepts ONLY Accepted=True that OUR controller
# wrote for AT LEAST the generation we just created. Everything else — no
# status, False, a stale observedGeneration, someone else's controller —
# must fail the canary.
set -euo pipefail
C="io.cilium/gateway-controller"
PASS=0; FAILED=0

condition() { jq -r --arg c "$C" '[.status.parents[]? | select(.controllerName==$c)
  | .conditions[]? | select(.type=="Accepted")]
  | first // {} | "\(.observedGeneration // "")|\(.status // "")"'; }

# accepts <json> <wanted-generation> → "yes" if the wait loop would proceed
accepts() {
  local result obs acc; result=$(printf '%s' "$1" | condition)
  obs=${result%%|*}; acc=${result##*|}
  case "${obs}" in ''|*[!0-9]*) echo no; return ;; esac
  [ "${obs}" -ge "$2" ] && [ "${acc}" = "True" ] && echo yes || echo no
}

run() {
  local name="$1" expect="$2" json="$3" gen="$4"
  local got; got=$(accepts "${json}" "${gen}")
  if [ "${got}" = "${expect}" ]; then echo "  ✓ ${name}: ${got}"; PASS=$((PASS+1))
  else echo "  ✗ ${name}: got ${got}, expected ${expect}"; FAILED=$((FAILED+1)); fi
}

echo "=== canary del controlador Gateway API: tabla de decisión ==="

run "controlador-vivo-al-dia" yes \
  '{"status":{"parents":[{"controllerName":"io.cilium/gateway-controller","conditions":[{"type":"Accepted","status":"True","observedGeneration":2}]}]}}' 2

# THE 4a SCENARIO: the controller never started, so nothing ever wrote status.
run "controlador-muerto-sin-status" no '{"status":{}}' 1
run "sin-campo-status" no '{}' 1

# THE 8th FACE, reproduced: a status that exists but describes an older
# generation is exactly "yesterday's answer", which is what fooled us.
run "status-rancio-generacion-vieja" no \
  '{"status":{"parents":[{"controllerName":"io.cilium/gateway-controller","conditions":[{"type":"Accepted","status":"True","observedGeneration":1}]}]}}' 2

# Advancing observedGeneration is not enough: the second generation must
# remain accepted after the mutation.
run "generacion-al-dia-pero-rechazada" no \
  '{"status":{"parents":[{"controllerName":"io.cilium/gateway-controller","conditions":[{"type":"Accepted","status":"False","observedGeneration":2}]}]}}' 2

# Someone else's controller reconciling is not ours working.
run "otro-controlador" no \
  '{"status":{"parents":[{"controllerName":"otro/controller","conditions":[{"type":"Accepted","status":"True","observedGeneration":5}]}]}}' 1

# A condition of the wrong type must not be read as acceptance.
run "condicion-de-otro-tipo" no \
  '{"status":{"parents":[{"controllerName":"io.cilium/gateway-controller","conditions":[{"type":"ResolvedRefs","status":"True","observedGeneration":2}]}]}}' 2

# Unreadable observedGeneration is not a pass.
run "observed-ilegible" no \
  '{"status":{"parents":[{"controllerName":"io.cilium/gateway-controller","conditions":[{"type":"Accepted","status":"True","observedGeneration":"n/a"}]}]}}' 1

# Ahead-of-request is fine: the controller has moved past what we asked.
run "controlador-mas-adelantado" yes \
  '{"status":{"parents":[{"controllerName":"io.cilium/gateway-controller","conditions":[{"type":"Accepted","status":"True","observedGeneration":7}]}]}}' 2

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
