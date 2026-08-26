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

make_stubs() {   # $1 = dir, $2 = bundle vivo, $3 = kinds vivos (espaciados)
  local d="$1" b="$2" k="$3"
  mkdir -p "$d/bin"
  cat > "$d/bin/kubectl" <<EOF
#!/usr/bin/env bash
ARGS="\$*"
case "\$ARGS" in
  *"get ns kube-system"*)  echo "uid-de-prueba" ;;
  *"config view"*)         echo "https://api.prueba:6443" ;;
  *"get crd -o json"*)
     printf '{"items":['
     first=1
     for kk in $k; do
       [ \$first -eq 0 ] && printf ','
       printf '{"metadata":{"name":"%s.gateway.networking.k8s.io","annotations":{"gateway.networking.k8s.io/bundle-version":"%s"}},"spec":{"group":"gateway.networking.k8s.io","versions":[{"name":"v1","served":true}]}}' "\$kk" "$b"
       first=0
     done
     printf ']}' ;;
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
    KUBECONFIG_OVERRIDE="$d/kubeconfig" AWS_PROFILE_OVERRIDE=stub \
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
echo "=== los CUATRO escalones invocan gate_6ab (el falso pase de v1.3/v1.4) ==="
for R in v1.3.0 v1.4.1 v1.5.1 v1.6.1; do
  if awk '/^close_rung\(\)/{f=1} f && /gate_6ab/{found=1} /^}/{if(f)exit} END{exit !found}' "$SRC"; then
    S=ok; else S=falta; fi
done
if [ "$S" = ok ]; then
  echo "  ✓ gate_6ab está DENTRO de close_rung → los 4 escalones lo ejecutan"; PASS=$((PASS+1))
else
  echo "  ✗ gate_6ab NO está en close_rung: v1.3.0/v1.4.1 cerrarían sin él"; FAILED=$((FAILED+1))
fi

echo ""
echo "=== LÍMITE DECLARADO de este arnés ==="
cat <<'NOTA'
  Solo se ejercitan los caminos que RECHAZAN. Los que permiten avanzar
  ejecutarían applies, diffs y el canary contra stubs, y un stub que
  devuelve 0 a todo probaría que el script llama a cosas, no que los gates
  funcionen — confianza falsa, que es lo que este arnés existe para no dar.
  Los caminos que permiten se validan contra un cluster REAL (el gate inicial
  ya se validó así el 25-ago) y sustituyó al arnés por extracción, que daba
  10/10 sin ejecutar un solo escalón y no vio el gate_6ab ausente.
NOTA

echo ""
echo "resultado: ${PASS} correctos, ${FAILED} incorrectos"
[ "${FAILED}" -eq 0 ] || exit 1
