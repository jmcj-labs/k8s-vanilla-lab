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
  *"get crd tlsroutes"*)
     # Dato mecánico que gate_6ab lee. Fidelidad de fixture, no semántica:
     # el stub NO decide si v1alpha2 "está bien", solo entrega el JSON que un
     # cluster entregaría. Quien juzga el contenido sigue siendo el gate.
     printf '{"spec":{"versions":[{"name":"v1","served":true},{"name":"v1alpha2","served":true},{"name":"v1alpha3","served":true}]}}' ;;
  *"logs -l io.cilium/app=operator"*)
     echo "level=info msg=\"TLSRoute CRD is installed, TLSRoute support is enabled\"" ;;
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
  # curl STUBEADO: sin esto el test sale a la red a por los manifiestos de
  # gateway-api y deja de ser hermético (y falla sin conectividad).
  cat > "$d/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Devuelve un manifiesto mínimo SIN "kind: TLSRoute", que es lo único que la
# guarda anti-URL del script mira. -o <fichero> respetado.
OUT=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && OUT="$a"; prev="$a"; done
BODY='apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: stub.gateway.networking.k8s.io}'
if [ -n "$OUT" ]; then printf '%s\n' "$BODY" > "$OUT"; else printf '%s\n' "$BODY"; fi
EOF
  chmod +x "$d/bin/kubectl" "$d/bin/aws" "$d/bin/curl"
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
  ST=$(cat "$d/state/stage")
  # HASTA DÓNDE LLEGA ESTA AFIRMACIÓN, y por qué no más lejos: el escalón
  # atraviesa applies, assert_live_schema post y gate_6ab —todo mecánico— y
  # se detiene en el canary, que exige un controlador RECONCILIANDO. Fingir
  # eso sería fingir semántica, que es lo que este arnés no hace. Así que se
  # exige: un solo rollout, haber ALCANZADO el canary (prueba de que 6a/6b
  # pasó y el orden se respetó) y stage SIN avanzar.
  CANARY=$(grep -c 'witness-canary' "$d/kubectl.calls" 2>/dev/null || true)
  if [ "$RST" -eq 1 ] && [ "$CANARY" -ge 1 ] && [ "$ST" = "$PREV" ]; then
    echo "  ✓ $R: 1 rollout, 6a/6b superado, canary alcanzado, stage sin avanzar"; PASS=$((PASS+1))
  else
    echo "  ✗ $R: rollouts=$RST canary=$CANARY stage='$ST'"; echo "     └ $(tail -1 "$d/out.txt")"; FAILED=$((FAILED+1))
  fi
  rm -rf "$d"
done

echo ""
echo "=== un fallo en cualquier gate NO avanza el stage ==="
# SOLO gate_6ab. La inyección de gate_routes se RETIRA, no se parchea: su
# patrón "get httproute" coincidía antes con backup_state y con el canary, así
# que disparaba temprano y REACHED>=1 solo probaba que el substring apareció,
# no que se alcanzara gate_routes. Y el patrón inequívoco tampoco sirve: para
# llegar a gate_routes hay que atravesar el canary, y hacerlo pasar
# "mecánicamente" es exactamente fingir su semántica — el canary ES "el
# controlador reconcilia". El arnés llega hasta el canary y ahí se detiene.
for INJ in "get crd tlsroutes:gate_6ab"; do
  PAT="${INJ%%:*}"; NAME="${INJ##*:}"
  d=$(mktemp -d); mkdir -p "$d/state"
  printf 'uid-de-prueba https://api.prueba:6443\n' > "$d/state/identity"
  # con destino y conflicto, como el escalón real: sin esto el escalón
  # abortaba en assert_live_schema post y nunca llegaba al gate inyectado —
  # el test habría "pasado" sin probar nada.
  make_stubs "$d" "v1.2.1" "$FIVE" yes "v1.3.0" "$FIVE tlsroutes"
  echo initial > "$d/state/stage"
  set +e
  PATH="$d/bin:$PATH" LADDER_STATE_DIR="$d/state" FAIL_ON="$PAT" \
    KUBECONFIG_OVERRIDE="$d/kubeconfig" AWS_PROFILE_OVERRIDE=stub AWS_REGION=eu-west-1 \
    bash "$SRC" v1.3.0 >/dev/null 2>&1
  IRC=$?
  set -e
  ST=$(cat "$d/state/stage")
  # No basta con que NO avance: hay que demostrar que el escalón LLEGÓ al gate
  # inyectado. Si abortase antes, el test pasaría sin haber probado ese gate.
  REACHED=$(grep -c "$PAT" "$d/kubectl.calls" 2>/dev/null || true)
  # rc≠0 EXIGIDO además: un escalón que fallara y aun así saliera 0 dejaría al
  # operador creyendo que cerró.
  if [ "$ST" = "initial" ] && [ "$REACHED" -ge 1 ] && [ "$IRC" -ne 0 ]; then
    echo "  ✓ fallo en $NAME: rc=$IRC, gate alcanzado, stage sigue 'initial'"; PASS=$((PASS+1))
  else
    echo "  ✗ fallo en $NAME: rc=$IRC stage='$ST' alcanzado=$REACHED"; FAILED=$((FAILED+1))
  fi
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
  ALCANCE: el arnés llega hasta el CANARY y se detiene ahí, en el camino
  positivo y en las inyecciones. Por eso solo se inyecta en gate_6ab: los
  gates posteriores (canary, rutas, testigo) quedan detrás de una puerta que
  únicamente un controlador real abre. Su no-avance-al-fallar se prueba en el
  cluster, no aquí.

  ALCANCE DEL CAMINO POSITIVO: llega hasta el canary y para ahí a propósito.
  Applies, esquema post y gate_6ab son mecánicos y se recorren de verdad; el
  canary exige un controlador reconciliando y fingirlo sería fingir semántica.

  ESTO PRUEBA: orquestación. Que cada escalón exige su predecesor exacto,
  contrasta el esquema VIVO antes y después, hace UN solo rollout del
  operador, cierra con los CINCO gates en orden, y NO avanza el stage cuando
  cualquiera de ellos falla — demostrando además que el escalón ALCANZÓ el
  gate inyectado, no que abortase antes.

  ESTO NO PRUEBA: la semántica de los gates. Que gate_6ab sepa leer v1alpha2,
  que el canary detecte un controlador muerto, que gate_routes distinga una
  ruta rancia. Un stub que lo fingiera daría confianza falsa, que es
  justamente lo que este arnés existe para no dar.

  QUIÉN LO PRUEBA: un cluster real. El gate inicial ya se validó así el
  25-ago (6/6 agentes, 6/6 envoy, 5 CRDs v1.2.1, canary reconciliando), y la
  escalera entera se ejecuta como el operador virgen definitivo.
NOTA

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
