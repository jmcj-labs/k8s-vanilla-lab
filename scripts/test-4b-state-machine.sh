#!/usr/bin/env bash
# Tabla de decisión de la máquina de estados de la escalera, EJECUTADA.
# Sin cluster: se prueban las transiciones, no los applies.
set -euo pipefail
PASS=0; FAILED=0
SRC="$(cd "$(dirname "$0")" && pwd)/run-4b-rung.sh"

# Extrae solo las funciones de estado del script real, para probar LO MISMO
# que corre en la ceremonia y no una copia que pueda divergir.
harness() {
  local dir="$1"
  cat <<EOF
set -euo pipefail
STATE_DIR="$dir"; mkdir -p "\$STATE_DIR"
STAGE_FILE="\$STATE_DIR/stage"; [ -f "\$STAGE_FILE" ] || echo none > "\$STAGE_FILE"
FAIL() { echo "FAIL: \$*" >&2; exit 1; }
OK()   { :; }
EOF
  # awk con bandera, no rangos de sed. Dos intentos previos fallaron aquí y
  # ninguno era culpa del script: `stage_get()` es de una línea sin `}` propio
  # (su rango se comía hasta stage_set), y dos rangos consecutivos duplicaban
  # require_stage. Se extrae el bloque contiguo de las tres funciones, hasta
  # la que viene después.
  awk '/^stage_get\(\)/{f=1} /^expect_bundle\(\)/{f=0} f' "$SRC"
  echo ""     # <- separador. Sin él, la llamada concatenada con ';' cae dentro
              #    de la última línea (un comentario) y NO se ejecuta: bash -c
              #    devuelve 0 y todos los casos "permiten". Tercer intento.
}

run_case() {
  local name="$1" expect="$2" start="$3" want="$4"
  local dir; dir=$(mktemp -d); echo "$start" > "$dir/stage"
  set +e
  bash -c "$(harness "$dir")
require_stage $want prueba" >/dev/null 2>&1
  local rc=$?
  set -e
  rm -rf "$dir"
  local got; [ $rc -eq 0 ] && got=PERMITE || got=RECHAZA
  if [ "$got" = "$expect" ]; then echo "  ✓ ${name}: ${got}"; PASS=$((PASS+1))
  else echo "  ✗ ${name}: ${got}, esperaba ${expect}"; FAILED=$((FAILED+1)); fi
}

echo "=== máquina de estados de la escalera 4b ==="
run_case "gate→v1.3.0 tras initial"        PERMITE initial initial
run_case "v1.3.0 sin gate previo (none)"   RECHAZA none    initial
run_case "SALTO v1.6.1 sobre v1.2.1"       RECHAZA initial v1.5.1
run_case "salto v1.5.1 sin v1.4.1"         RECHAZA v1.3.0  v1.4.1
run_case "repetir un escalón ya cerrado"   RECHAZA v1.4.1  v1.3.0
run_case "orden correcto v1.4.1→v1.5.1"    PERMITE v1.4.1  v1.4.1
run_case "final sin v1.6.1"                RECHAZA v1.5.1  v1.6.1
run_case "final tras v1.6.1"               PERMITE v1.6.1  v1.6.1

# stage_set debe ser atómico y dejar el valor exacto
D=$(mktemp -d); echo none > "$D/stage"
bash -c "$(harness "$D")
stage_set v1.4.1" >/dev/null 2>&1
V=$(cat "$D/stage")
if [ "$V" = "v1.4.1" ]; then echo "  ✓ stage_set escribe el valor exacto"; PASS=$((PASS+1))
else echo "  ✗ stage_set dejó '$V'"; FAILED=$((FAILED+1)); fi
ls "$D"/.stage.* >/dev/null 2>&1 && { echo "  ✗ dejó temporales sin mover"; FAILED=$((FAILED+1)); } \
  || { echo "  ✓ sin temporales huérfanos (temp+mv atómico)"; PASS=$((PASS+1)); }
rm -rf "$D"

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
