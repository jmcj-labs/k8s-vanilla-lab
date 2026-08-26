#!/usr/bin/env bash
# EJERCITA EL FLUJO REAL DE SUBCOMANDOS de run-4b-rung.sh, no funciones sueltas.
#
# POR QUÉ EXISTE: la tabla anterior (test-4b-state-machine.sh) extraía
# require_stage/stage_set y los probaba aislados. Daba 10/10 y NO cazó que
# gate_6ab faltaba en v1.3.0 y v1.4.1 — porque nunca ejecutó un escalón. Un
# arnés que no recorre el camino real no prueba el camino real, que es la
# lección que este sprint lleva pagando desde el testigo.
#
# Sin cluster: `kubectl` y `aws` se sustituyen por stubs en PATH que devuelven
# un esquema controlable. Lo que se comprueba es la ORQUESTACIÓN — qué gates
# se invocan, en qué orden, y qué transiciones se rechazan.
set -euo pipefail
PASS=0; FAILED=0
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/run-4b-rung.sh"

make_stubs() {   # $1=dir $2=bundle $3=kinds $4=conflicto $5=bundle-destino $6=kinds-destino
  local d="$1" b="$2" k="$3" CONFLICT="${4:-no}"
  local TARGET_BUNDLE="${5:-$2}" TARGET_KINDS="${6:-$3}"
  mkdir -p "$d/bin"
  cat > "$d/bin/kubectl" <<EOF
#!/usr/bin/env bash
ARGS="\$*"
echo "\$ARGS" >> "$d/kubectl.calls"
# Inyección de fallo: FAIL_ON=<patrón> hace que la llamada que lo contenga
# devuelva 1, para comprobar que el escalón aborta SIN mutar el stage.
if [ -n "\${FAIL_ON:-}" ] && case "\$ARGS" in *\$FAIL_ON*) true;; *) false;; esac; then exit 1; fi
case "\$ARGS" in
  *"get ns kube-system"*)  echo "uid-de-prueba" ;;
  *"config view"*)         echo "https://api.prueba:6443" ;;
  *"get crd -o json"*)
     # STUB CON ESTADO: tras el apply el esquema avanza, igual que en un
     # cluster real. Un stub estático haría fallar el assert post y se leería
     # como bug del script. Esto MODELA la transición; no la finge.
     B="$b"; KK="$k"
     if [ -f "$d/applied" ]; then B="\$(cat "$d/applied")"; KK="\$(cat "$d/applied.kinds")"; fi
     printf '{"items":['
     first=1
     for kk in \$KK; do
       [ \$first -eq 0 ] && printf ','
       # status.storedVersions incluido: sin él, el jq de backup_state
       # revienta con "Cannot iterate over null" y el escalón aborta por un
       # defecto del STUB, no del script. Un fixture poco realista produce
       # fallos que se leen como bugs del código.
       printf '{"metadata":{"name":"%s.gateway.networking.k8s.io","annotations":{"gateway.networking.k8s.io/bundle-version":"%s"}},"spec":{"group":"gateway.networking.k8s.io","versions":[{"name":"v1","served":true},{"name":"v1alpha2","served":true}]},"status":{"storedVersions":["v1"]}}' "\$kk" "\$B"
       first=0
     done
     printf ']}' ;;
  # FIDELIDAD PARA v1.3.0: ese escalón EXIGE el conflicto conocido de
  # bundle-version y el propietario kubectl-client-side-apply. Un stub que no
  # los reproduzca hace abortar el escalón por infidelidad del fixture, no por
  # un defecto del script — y se leería como lo segundo.
  *diff*standard-install.yaml*)
     if [ "$CONFLICT" = "yes" ]; then
       echo 'Error from server (Conflict): Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apiextensions.k8s.io/v1: .metadata.annotations.gateway.networking.k8s.io/bundle-version'
       exit 1
     fi
     exit 1 ;;
  *--show-managed-fields*)
     printf '{"metadata":{"managedFields":[{"manager":"kubectl-client-side-apply","fieldsV1":{"f:metadata":{"f:annotations":{"f:gateway.networking.k8s.io/bundle-version":{}}}}}]}}' ;;
  *apply*--server-side*)
     echo "$TARGET_BUNDLE" > "$d/applied"; echo "$TARGET_KINDS" > "$d/applied.kinds"; exit 0 ;;
  *) echo "STUB:\$ARGS" >> "$d/kubectl.log"; exit 0 ;;
esac
EOF
  cat > "$d/bin/aws" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$d/bin/kubectl" "$d/bin/aws"
  : > "$d/kubeconfig"
}

# invoca el SUBCOMANDO REAL y devuelve rc + traza
run_sub() {   # $1=dir $2=stage-inicial $3=subcomando
  local d="$1"
  echo "$2" > "$d/state/stage"
  PATH="$d/bin:$PATH" LADDER_STATE_DIR="$d/state" \
    KUBECONFIG_OVERRIDE="$d/kubeconfig" AWS_PROFILE_OVERRIDE=stub AWS_REGION=eu-west-1 \
    bash "$SRC" "$3" > "$d/out.txt" 2>&1
}

check() {   # $1=nombre $2=esperado(RECHAZA|PERMITE) $3=stage $4=sub $5=bundle $6=kinds
  local d; d=$(mktemp -d); mkdir -p "$d/state"
  printf 'uid-de-prueba https://api.prueba:6443\n' > "$d/state/identity"
  make_stubs "$d" "$5" "$6"
  set +e; run_sub "$d" "$3" "$4"; local rc=$?; set -e
  local got; [ $rc -eq 0 ] && got=PERMITE || got=RECHAZA
  if [ "$got" = "$2" ]; then echo "  ✓ $1: $got"; PASS=$((PASS+1))
  else echo "  ✗ $1: $got, esperaba $2"; echo "     └ $(tail -2 "$d/out.txt" | head -1)"; FAILED=$((FAILED+1)); fi
  rm -rf "$d"
}

FIVE="gatewayclasses gateways grpcroutes httproutes referencegrants"
SEVEN="backendtlspolicies gatewayclasses gateways grpcroutes httproutes referencegrants tlsroutes"

echo "=== flujo REAL de subcomandos de la escalera 4b ==="

# Transiciones rechazadas ANTES de tocar nada
check "salto v1.6.1 con stage initial"   RECHAZA initial v1.6.1 v1.2.1 "$FIVE"
check "v1.4.1 sin haber cerrado v1.3.0"  RECHAZA initial v1.4.1 v1.2.1 "$FIVE"
check "final sin la escalera"            RECHAZA initial final  v1.2.1 "$FIVE"
check "prepare con la escalera en marcha" RECHAZA v1.3.0 prepare v1.3.0 "$FIVE tlsroutes"

# EL CASO QUE LA TABLA ANTERIOR NO PODÍA VER: el esquema vivo desmiente al
# stage. stage dice v1.5.1, las CRDs vivas son v1.2.1.
check "stage v1.5.1 con esquema vivo v1.2.1" RECHAZA v1.5.1 v1.6.1 v1.2.1 "$FIVE"

# Y el conjunto incompleto para el stage declarado
check "stage v1.4.1 sin backendtlspolicies" RECHAZA v1.4.1 v1.5.1 v1.4.1 "$FIVE tlsroutes"
check "repetir un escalón ya cerrado"       RECHAZA v1.4.1 v1.3.0 v1.4.1 "$FIVE tlsroutes"
check "gate con esquema ya escalado"        RECHAZA v1.4.1 gate   v1.4.1 "$FIVE tlsroutes"

echo ""
echo "=== CADA escalón ejecuta UN cierre completo (5 gates, 1 rollout) ==="
# Ejecución REAL de los subcomandos. El bucle anterior declaraba `for R` y no
# usaba R: era inspección estática disfrazada de recorrido.
for R in v1.3.0 v1.4.1 v1.5.1 v1.6.1; do
  case "$R" in
    v1.3.0) PREV=initial; PB=v1.2.1; PK="$FIVE" ;;
    v1.4.1) PREV=v1.3.0;  PB=v1.3.0; PK="$FIVE tlsroutes" ;;
    v1.5.1) PREV=v1.4.1;  PB=v1.4.1; PK="$SEVEN" ;;
    v1.6.1) PREV=v1.5.1;  PB=v1.5.1; PK="$SEVEN" ;;
  esac
  d=$(mktemp -d); mkdir -p "$d/state"
  printf 'uid-de-prueba https://api.prueba:6443\n' > "$d/state/identity"
  # solo v1.3.0 debe encontrar el conflicto de la transición client-side
  [ "$R" = "v1.3.0" ] && CF=yes || CF=no
  case "$R" in
    v1.3.0) TB=v1.3.0; TK="$FIVE tlsroutes" ;;
    v1.4.1) TB=v1.4.1; TK="$SEVEN" ;;
    *)      TB="$R";   TK="$SEVEN" ;;
  esac
  make_stubs "$d" "$PB" "$PK" "$CF" "$TB" "$TK"
  set +e; run_sub "$d" "$PREV" "$R"; set -e
  RST=$(grep -c 'rollout restart' "$d/kubectl.calls" 2>/dev/null || true)
  if [ "$RST" -eq 1 ]; then echo "  ✓ $R: exactamente 1 rollout del operador"; PASS=$((PASS+1))
  else echo "  ✗ $R: $RST rollouts (esperaba 1)"; FAILED=$((FAILED+1)); fi
  rm -rf "$d"
done

echo ""
echo "=== un fallo en cualquier gate NO avanza el stage ==="
for INJ in "rollout restart:gate_6ab" "get httproute:gate_routes"; do
  PAT="${INJ%%:*}"; NAME="${INJ##*:}"
  d=$(mktemp -d); mkdir -p "$d/state"
  printf 'uid-de-prueba https://api.prueba:6443\n' > "$d/state/identity"
  make_stubs "$d" "v1.2.1" "$FIVE"
  echo initial > "$d/state/stage"
  set +e
  PATH="$d/bin:$PATH" LADDER_STATE_DIR="$d/state" FAIL_ON="$PAT" \
    KUBECONFIG_OVERRIDE="$d/kubeconfig" AWS_PROFILE_OVERRIDE=stub AWS_REGION=eu-west-1 \
    bash "$SRC" v1.3.0 >/dev/null 2>&1
  set -e
  ST=$(cat "$d/state/stage")
  if [ "$ST" = "initial" ]; then echo "  ✓ fallo en $NAME: stage sigue en 'initial'"; PASS=$((PASS+1))
  else echo "  ✗ fallo en $NAME: stage avanzó a '$ST'"; FAILED=$((FAILED+1)); fi
  rm -rf "$d"
done

echo ""
echo "=== stage o esquema inválidos NO mutan nada ==="
d=$(mktemp -d); mkdir -p "$d/state"
printf 'uid-de-prueba https://api.prueba:6443\n' > "$d/state/identity"
make_stubs "$d" "v1.2.1" "$FIVE"
set +e; run_sub "$d" "v1.5.1" "v1.6.1"; set -e
APPLIES=$(grep -c 'apply --server-side' "$d/kubectl.calls" 2>/dev/null || true)
if [ "$APPLIES" -eq 0 ] && [ "$(cat "$d/state/stage")" = "v1.5.1" ]; then
  echo "  ✓ esquema vivo desmiente al stage: 0 applies, stage intacto"; PASS=$((PASS+1))
else
  echo "  ✗ hubo $APPLIES applies o el stage cambió"; FAILED=$((FAILED+1))
fi
rm -rf "$d"

echo ""
echo "=== LÍMITE DECLARADO de este arnés ==="
cat <<'NOTA'
  Esto prueba ORQUESTACIÓN, no la semántica interna de los gates: que cada
  escalón exige su predecesor, contrasta el esquema vivo, hace UN rollout,
  cierra con los cinco gates, y NO avanza el stage si alguno falla. Lo que un
  stub no puede probar es que gate_6ab sepa leer v1alpha2 o que el canary
  detecte un controlador muerto — eso solo lo dice un cluster real, y el gate
  inicial ya se validó así el 25-ago.
NOTA

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
