#!/usr/bin/env bash
# 4b — la escalera de Gateway API, UN ESCALÓN POR INVOCACIÓN.
#
# WHY A SCRIPT WITH ONE SUBCOMMAND PER RUNG, and not the two obvious
# alternatives:
#
#   · A runbook of blocks to paste needs every block to share one shell
#     session, because the gates are functions. "Run these in one session" is
#     PROSE, and prose does not execute — the lesson this sprint keeps paying
#     for. A paste into a fresh terminal would silently lose every gate.
#   · A single script that runs the whole ladder removes the human stop
#     BETWEEN rungs, which is the heart of the design: look at the witness,
#     decide, then continue.
#
# One invocation per rung gives both: each run is self-contained, and the
# operator decides between them. State that must survive across invocations
# (the witness's last sent count) is persisted to disk, not to a variable.
set -euo pipefail

MODE="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"

# EL SCRIPT FIJA SU PROPIO ENTORNO. Heredarlo de la terminal permite que una
# ventana nueva —o una con AWS_PROFILE de otro perfil— apunte a un cluster
# distinto a mitad de ceremonia. La ceremonia decide contra qué habla.
export AWS_PROFILE="${AWS_PROFILE_OVERRIDE:-k8s-vanilla-lab}"
export KUBECONFIG="${KUBECONFIG_OVERRIDE:-$HOME/.kube/${CLUSTER_NAME}.conf}"
[ -r "$KUBECONFIG" ] || { echo "✗ no puedo leer KUBECONFIG=$KUBECONFIG (make kubeconfig)" >&2; exit 1; }

WITNESS_STATE_DIR="${WITNESS_STATE_DIR:-/tmp/witness-${CLUSTER_NAME}}"
FM=gateway-api-crd-upgrade
STD=https://github.com/kubernetes-sigs/gateway-api/releases/download
EXP=https://raw.githubusercontent.com/kubernetes-sigs/gateway-api
SIX="gatewayclasses gateways httproutes grpcroutes referencegrants backendtlspolicies"
EXPECTED_ROUTES='["GRPCRoute/logistics/routing","HTTPRoute/logistics/shipments-api"]'

log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
OK()   { echo "  ✓ $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }
overlay() { echo "$EXP/$1/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml"; }
indiv()   { echo "$EXP/$1/config/crd/standard/gateway.networking.k8s.io_$2.yaml"; }

# ── IDENTIDAD DE LA CEREMONIA ───────────────────────────────────────────────
# El estado en disco se ata al CLUSTER, no a una ruta fija. Sin esto, una
# encarnación nueva heredaría el stage de la anterior y creería ir por v1.5.1
# sobre un cluster que acaba de nacer en v1.2.1.
cluster_uid() { kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null; }
api_endpoint() { kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null; }

CUID="$(cluster_uid)"; APIEP="$(api_endpoint)"
[ -n "$CUID" ] && [ -n "$APIEP" ] || FAIL "no puedo identificar el cluster (¿kubeconfig válido?)"
STATE_DIR="${LADDER_STATE_DIR:-/tmp/4b-ladder-${CUID}}"
mkdir -p "$STATE_DIR"

IDFILE="$STATE_DIR/identity"
if [ -f "$IDFILE" ]; then
  read -r OLD_UID OLD_EP < "$IDFILE"
  [ "$OLD_UID" = "$CUID" ] && [ "$OLD_EP" = "$APIEP" ] \
    || FAIL "el estado de $STATE_DIR pertenece a OTRA ceremonia
  guardado: uid=$OLD_UID endpoint=$OLD_EP
  actual:   uid=$CUID endpoint=$APIEP
  Borra el directorio si de verdad quieres empezar de cero."
else
  printf '%s %s\n' "$CUID" "$APIEP" > "$IDFILE"
fi

# ── MÁQUINA DE ESTADOS ──────────────────────────────────────────────────────
# stage = el último escalón CERRADO. Cada subcomando exige el anterior EXACTO,
# así que v1.6.1 sobre un cluster en v1.2.1 se rechaza ANTES de tocar nada.
STAGE_FILE="$STATE_DIR/stage"
[ -f "$STAGE_FILE" ] || echo "none" > "$STAGE_FILE"
stage_get() { cat "$STAGE_FILE"; }
stage_set() {   # atómico: temp + mv, para que un corte no deje media transición
  local tmp; tmp="$(mktemp "$STATE_DIR/.stage.XXXXXX")"
  printf '%s\n' "$1" > "$tmp"; mv -f "$tmp" "$STAGE_FILE"
  OK "stage → $1"
}
require_stage() {   # $1 = stage exigido, $2 = etiqueta del escalón
  local cur; cur="$(stage_get)"
  [ "$cur" = "$1" ] || FAIL "[$2] este escalón exige stage='$1' y el actual es '$cur'.
  La escalera NO se salta: ejecuta los escalones en orden."
}
# El bundle que DEBE quedar tras cada escalón, comprobado antes de avanzar.
expect_bundle() {   # $1 = versión esperada, $2 = etiqueta
  local B
  B=$(kubectl get crd gateways.gateway.networking.k8s.io -o json \
      | jq -r '.metadata.annotations["gateway.networking.k8s.io/bundle-version"] // ""')
  echo "  [$2] bundle tras aplicar: $B (esperado $1)"
  [ "$B" = "$1" ] || FAIL "[$2] el esquema resultante NO es $1"
}

# ── EL TESTIGO NO PUEDE ESTAR MUERTO ────────────────────────────────────────
# Idéntica lección a la del propio testigo (INCIDENTS #17, 6ª cara): si el
# bucle muere tras el gate inicial, la serie se congela con sent == successful
# y PASARÍA todos los cierres. Un testigo parado no es un testigo que no vio
# nada malo. Se exige CRECIMIENTO respecto al último cierre, y latido fresco.
gate_witness() {
  local tag="$1" S="${WITNESS_STATE_DIR}/series" LAST=0 SENT OK_N HB AGE TOL=32
  [ -s "$S" ] || FAIL "[$tag] serie del testigo ausente o vacía"
  [ -f "$STATE_DIR/last_sent" ] && LAST=$(cat "$STATE_DIR/last_sent")
  SENT=$(awk '$3!="event"{n++} END{print n+0}' "$S")
  OK_N=$(awk '$3!="event" && $4=="ok"{n++} END{print n+0}' "$S")
  HB=$(cat "${WITNESS_STATE_DIR}/heartbeat" 2>/dev/null || echo 0)
  case "$HB" in ''|*[!0-9]*) FAIL "[$tag] latido ilegible ('$HB')" ;; esac
  AGE=$(( $(date -u +%s) - HB ))
  echo "  [$tag] testigo: sent=$SENT (anterior $LAST) successful=$OK_N latido=${AGE}s"
  [ "$SENT" -gt "$LAST" ] || FAIL "[$tag] la serie NO creció desde el cierre anterior
  ($LAST → $SENT): el testigo está PARADO, no limpio"
  [ "$AGE" -le "$TOL" ] || FAIL "[$tag] latido de ${AGE}s (tolerancia ${TOL}s): el bucle murió"
  [ "$SENT" -eq "$OK_N" ] || FAIL "[$tag] el testigo registró PÉRDIDA ($((SENT-OK_N)) fallos)"
  # LAST_SENT vive en STATE_DIR, que cuelga del UID del cluster: no puede
  # arrastrarse de otra encarnación. Y solo avanza TRAS pasar los tres gates.
  echo "$SENT" > "$STATE_DIR/last_sent"
  OK "[$tag] testigo vivo, creciendo y sin pérdida"
}

gate_routes() {
  kubectl get httproute,grpcroute -A -o json | jq -e --argjson want "$EXPECTED_ROUTES" '
    def bad:
      .metadata.generation as $g
      | ((.status.parents // []) | length) == 0
        or (any(.status.parents[];
              ((.conditions // []) | length) == 0
              or any(.conditions[]; (.observedGeneration // -1) != $g)
              or ((any(.conditions[]; .type=="Accepted"     and .status=="True")) | not)
              or ((any(.conditions[]; .type=="ResolvedRefs" and .status=="True")) | not)
           ));
    ([ .items[] | "\(.kind)/\(.metadata.namespace)/\(.metadata.name)" ] | sort) == ($want | sort)
    and ([ .items[] | select(bad) ] | length) == 0
  ' >/dev/null || FAIL "[$1] rutas: conjunto o vigencia incorrectos"
  OK "[$1] rutas: conjunto exacto, Accepted+ResolvedRefs, obsGen==gen"
}

gate_controller() {
  bash "$REPO_ROOT/scripts/verify-gateway-controller.sh" "$1" \
    || FAIL "[$1] el controlador NO reconcilia"
}

gate_6ab() {
  kubectl -n kube-system rollout restart deploy/cilium-operator >/dev/null
  kubectl -n kube-system rollout status deploy/cilium-operator --timeout=120s >/dev/null
  local SERVED E
  SERVED=$(kubectl get crd tlsroutes.gateway.networking.k8s.io -o json \
           | jq -r '[.spec.versions[]|select(.served==true)|.name]|join(" ")')
  [ -n "$SERVED" ] || FAIL "[$1] no pude LEER las versiones servidas de tlsroutes"
  echo "  [$1] tlsroutes servidas: $SERVED"
  echo "$SERVED" | grep -qw v1alpha2 || FAIL "[$1] v1alpha2 PERDIDA → ROLLBACK"
  # El grep mira TODOS los pods del operador, no `deploy/` (que elige uno):
  # solo el líder emite el módulo gateway-api, y kubectl podría leer al otro.
  kubectl -n kube-system logs -l io.cilium/app=operator --tail=-1 --prefix 2>/dev/null \
    | grep -q "TLSRoute support is enabled" \
    || FAIL "[$1] el operador NO habilita TLSRoute → ROLLBACK"
  E=$(kubectl -n kube-system logs -l io.cilium/app=operator --tail=-1 2>/dev/null \
      | grep -c "Required GatewayAPI resources are not found" || true)
  echo "  [$1] errores de CRD requeridas: $E (esperado 0)"
  [ "$E" -eq 0 ] || FAIL "[$1] PARAR"
  OK "[$1] gate 6a/6b"
}

backup_state() {
  local D="$STATE_DIR/backup-$1-$(date -u +%Y%m%dT%H%M%SZ)"
  [ -e "$D" ] && FAIL "el backup $D ya existe (no se sobrescribe evidencia)"
  mkdir -p "$D"
  local K
  for K in $SIX tlsroutes; do
    # Solo se tolera NotFound (tlsroutes aún no existe en los primeros
    # escalones). Cualquier otro error del API es un backup incompleto.
    if ! kubectl get "$K.gateway.networking.k8s.io" -A -o yaml > "$D/objects-$K.yaml" 2>"$D/err-$K"; then
      grep -qi "NotFound\|the server doesn't have a resource type" "$D/err-$K" \
        || FAIL "backup de $K falló por algo que NO es NotFound: $(head -1 "$D/err-$K")"
      rm -f "$D/objects-$K.yaml"
    fi
    rm -f "$D/err-$K"
  done
  kubectl get crd -o json | jq '[.items[]|select(.spec.group=="gateway.networking.k8s.io")]' > "$D/crds.json"
  kubectl get crd -o json | jq -r '.items[]|select(.spec.group=="gateway.networking.k8s.io")
    | "\(.metadata.name) stored=\(.status.storedVersions|join(",")) served=\([.spec.versions[]|select(.served==true)|.name]|join(","))"' \
    | sort > "$D/stored-before.txt"
  OK "backup en $D"
}

close_rung() { gate_controller "$1"; gate_routes "$1"; gate_witness "$1"; echo "══ escalón $1 CERRADO ══"; }

# ── GATE DE ESTADO DE PARTIDA ───────────────────────────────────────────────
cmd_gate() {
  log "=== gate de estado de partida ==="
  local AG EV OPIMG RR DR
  # Cantidad EXACTA y Ready: 6 sanos + 1 malo debe FALLAR, así que se cuenta
  # el total además de los sanos.
  AG=$(kubectl -n kube-system get pods -l k8s-app=cilium \
       -o jsonpath='{range .items[*]}{.spec.containers[0].image}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' \
       | grep -c 'v1\.19\.6.*true' || true)
  EV=$(kubectl -n kube-system get pods -l k8s-app=cilium-envoy \
       -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
       | grep -c true || true)
  local AGT EVT
  AGT=$(kubectl -n kube-system get pods -l k8s-app=cilium --no-headers | wc -l | tr -d ' ')
  EVT=$(kubectl -n kube-system get pods -l k8s-app=cilium-envoy --no-headers | wc -l | tr -d ' ')
  echo "  control: esperaba 6/6 agentes 1.19.6 Ready y 6/6 envoy Ready; encontré $AG/$AGT y $EV/$EVT"
  [ "$AG" -eq 6 ] && [ "$AGT" -eq 6 ] && [ "$EV" -eq 6 ] && [ "$EVT" -eq 6 ] \
    || FAIL "el DaemonSet no está sano en los 6 nodos"

  # IMÁGENES DE LOS PODS REALES, no de la plantilla: un rollout a medias deja
  # pods VIEJOS en Ready, y la plantilla ya anuncia la versión nueva. Contar
  # los que corren la esperada es lo único que distingue ambos casos.
  local EVIMG_OK OPPODS OPIMG_OK UR
  EVIMG_OK=$(kubectl -n kube-system get pods -l k8s-app=cilium-envoy \
    -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep -c 'v1\.36\.9' || true)
  echo "  control: esperaba 6 pods cilium-envoy en v1.36.9, encontré $EVIMG_OK"
  [ "$EVIMG_OK" -eq 6 ] || FAIL "los pods de cilium-envoy no corren la imagen de 1.19.6"

  OPPODS=$(kubectl -n kube-system get pods -l io.cilium/app=operator --no-headers 2>/dev/null | wc -l | tr -d ' ')
  OPIMG_OK=$(kubectl -n kube-system get pods -l io.cilium/app=operator \
    -o jsonpath='{range .items[*]}{.spec.containers[0].image}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    | grep -c 'v1\.19\.6.*true' || true)
  RR=$(kubectl -n kube-system get deploy cilium-operator -o jsonpath='{.status.readyReplicas}')
  DR=$(kubectl -n kube-system get deploy cilium-operator -o jsonpath='{.spec.replicas}')
  UR=$(kubectl -n kube-system get deploy cilium-operator -o jsonpath='{.status.updatedReplicas}')
  echo "  control: operador pods=$OPPODS en-version-y-Ready=$OPIMG_OK ready=$RR updated=$UR desired=$DR"
  [ "${RR:-0}" -eq "${DR:-0}" ] && [ "${UR:-0}" -eq "${DR:-0}" ] && [ "${RR:-0}" -ge 1 ] \
    || FAIL "el operador no está completo (rollout a medias)"
  [ "$OPIMG_OK" -eq "$OPPODS" ] && [ "$OPPODS" -ge 1 ] \
    || FAIL "algún pod del operador NO corre v1.19.6"

  kubectl get crd -o json | jq -e '
    [ .items[] | select(.spec.group=="gateway.networking.k8s.io")
      | {n: .metadata.name, b: .metadata.annotations["gateway.networking.k8s.io/bundle-version"]} ] as $c
    | ([$c[].n] | sort) == ["gatewayclasses.gateway.networking.k8s.io","gateways.gateway.networking.k8s.io","grpcroutes.gateway.networking.k8s.io","httproutes.gateway.networking.k8s.io","referencegrants.gateway.networking.k8s.io"]
      and all($c[]; .b == "v1.2.1")
  ' >/dev/null || FAIL "el punto de partida NO es exactamente el conjunto v1.2.1"
  OK "5 CRDs, todas bundle v1.2.1"

  gate_controller estado-inicial
  gate_routes estado-inicial
  : > "$STATE_DIR/last_sent"; echo 0 > "$STATE_DIR/last_sent"
  gate_witness estado-inicial
  log "=== ESTADO DE PARTIDA CORRECTO — la escalera puede empezar ==="
}

# ── ESCALONES ───────────────────────────────────────────────────────────────
apply_bundle_v130() {
  # spec.infrastructure contra el Gateway VIVO: si existe, PARA.
  local INFRA
  INFRA=$(kubectl -n infra get gateway shared-gw -o jsonpath='{.spec.infrastructure}')
  [ -z "$INFRA" ] || FAIL "spec.infrastructure NO vacío ('$INFRA') — revisar v1.3 antes de subir"

  local RC=0 DOUT="$STATE_DIR/diff-standard-v1.3.0.txt"
  CRD_DIFF_OUT="$DOUT" bash "$REPO_ROOT/scripts/crd-diff-gate.sh" \
    "$STD/v1.3.0/standard-install.yaml" standard-v1.3.0 || RC=$?
  [ "$RC" -eq 3 ] || FAIL "esperaba rc=3 (conflicto conocido), obtuve rc=$RC"

  # EL DIFF DICE QUÉ CONFLICTO ES, y rc=3 solo dice que hubo alguno. Se exige
  # el conjunto EXACTO autorizado: un único campo (bundle-version) y un único
  # manager (kubectl-client-side-apply). Cualquier campo o manager de más
  # significa que estaríamos forzando algo que nadie revisó.
  local FIELDS MANAGERS
  FIELDS=$(grep -oE '\.metadata\.annotations\.[^ ,]+' "$DOUT" | sort -u | tr '\n' ' ')
  MANAGERS=$(grep -oE 'conflict with "[^"]+"' "$DOUT" | sed 's/conflict with //;s/"//g' | sort -u | tr '\n' ' ')
  echo "  campos en conflicto:   ${FIELDS:-<ninguno>}"
  echo "  managers en conflicto: ${MANAGERS:-<ninguno>}"
  [ "$(echo $FIELDS)" = ".metadata.annotations.gateway.networking.k8s.io/bundle-version" ] \
    || FAIL "el conflicto NO se limita a bundle-version — force NO autorizado"
  [ "$(echo $MANAGERS)" = "kubectl-client-side-apply" ] \
    || FAIL "hay managers en conflicto además del del bootstrap — force NO autorizado"

  # EL FORCE SE ACOTA EN LAS CINCO, no en una. rc=3 solo dice "algún
  # conflicto"; autorizar el force del bundle sin mirar las cinco permitiría
  # arrastrar un conflicto AJENO en otra CRD.
  local K OWNERS
  for K in gatewayclasses gateways httproutes grpcroutes referencegrants; do
    OWNERS=$(kubectl get crd "$K.gateway.networking.k8s.io" --show-managed-fields -o json \
      | jq -r '[.metadata.managedFields[] | select(.fieldsV1."f:metadata"."f:annotations"."f:gateway.networking.k8s.io/bundle-version") | .manager] | join(",")')
    echo "  $K → bundle-version en poder de: ${OWNERS:-<nadie>}"
    [ "$OWNERS" = "kubectl-client-side-apply" ] \
      || FAIL "$K: propietario inesperado ('${OWNERS:-<nadie>}') — el force NO está autorizado"
  done
  OK "las 5 CRDs: conflicto acotado a bundle-version bajo kubectl-client-side-apply"

  bash "$REPO_ROOT/scripts/crd-diff-gate.sh" "$(overlay v1.3.0)" tlsroute-v1.3.0
  kubectl apply --server-side --field-manager=$FM --force-conflicts -f "$STD/v1.3.0/standard-install.yaml"
  kubectl apply --server-side --field-manager=$FM -f "$(overlay v1.3.0)"
}

apply_bundle_v141() {
  bash "$REPO_ROOT/scripts/crd-diff-gate.sh" "$STD/v1.4.1/standard-install.yaml" standard-v1.4.1
  bash "$REPO_ROOT/scripts/crd-diff-gate.sh" "$(overlay v1.4.1)" tlsroute-v1.4.1
  kubectl apply --server-side --field-manager=$FM -f "$STD/v1.4.1/standard-install.yaml"
  kubectl apply --server-side --field-manager=$FM -f "$(overlay v1.4.1)"
}

apply_individual() {   # $1 = versión (v1.5.1 | v1.6.1)
  local V="$1" K
  for K in $SIX; do
    # A FICHERO ANTES DE GREP: `curl | grep -q` cierra la tubería al primer
    # match y curl muere con SIGPIPE, que bajo `set -o pipefail` aborta la
    # ceremonia por haber encontrado justo lo que buscaba.
    local TMPM; TMPM="$(mktemp)"
    curl -sfL "$(indiv "$V" "$K")" -o "$TMPM" || FAIL "no pude descargar $K de $V"
    if grep -q "kind: TLSRoute" "$TMPM"; then rm -f "$TMPM"; FAIL "$K de $V trae TLSRoute — URL equivocada"; fi
    rm -f "$TMPM"
    bash "$REPO_ROOT/scripts/crd-diff-gate.sh" "$(indiv "$V" "$K")" "$K-$V"
  done
  bash "$REPO_ROOT/scripts/crd-diff-gate.sh" "$(overlay "$V")" "tlsroute-$V"
  for K in $SIX; do kubectl apply --server-side --field-manager=$FM -f "$(indiv "$V" "$K")"; done
  kubectl apply --server-side --field-manager=$FM -f "$(overlay "$V")"   # el overlay, EL ÚLTIMO
}

restart_operator() {
  kubectl -n kube-system rollout restart deploy/cilium-operator >/dev/null
  kubectl -n kube-system rollout status deploy/cilium-operator --timeout=120s >/dev/null
}

case "$MODE" in
  prepare)
          log "=== FASE 0 — la app viva y el testigo midiendo ==="
          bash "$REPO_ROOT/scripts/prepare-4b-phase0.sh"
          ;;
  gate)   cmd_gate; stage_set initial ;;

  v1.3.0) require_stage initial v1.3.0
          log "=== escalón v1.2.1 → v1.3.0 ==="
          backup_state v1.3.0; apply_bundle_v130; restart_operator
          expect_bundle v1.3.0 v1.3.0
          close_rung v1.3.0; stage_set v1.3.0 ;;

  v1.4.1) require_stage v1.3.0 v1.4.1
          log "=== escalón v1.3.0 → v1.4.1 ==="
          backup_state v1.4.1; apply_bundle_v141; restart_operator
          expect_bundle v1.4.1 v1.4.1
          close_rung v1.4.1; stage_set v1.4.1 ;;

  v1.5.1) require_stage v1.4.1 v1.5.1
          log "=== escalón v1.4.1 → v1.5.1 (6 individuales, TLSRoute excluido) ==="
          backup_state v1.5.1; apply_individual v1.5.1
          expect_bundle v1.5.1 v1.5.1
          gate_6ab v1.5.1; close_rung v1.5.1; stage_set v1.5.1 ;;

  v1.6.1) require_stage v1.5.1 v1.6.1
          log "=== escalón v1.5.1 → v1.6.1 (6 individuales, TLSRoute excluido) ==="
          backup_state v1.6.1; apply_individual v1.6.1
          expect_bundle v1.6.1 v1.6.1
          gate_6ab v1.6.1; close_rung v1.6.1; stage_set v1.6.1 ;;

  final)  require_stage v1.6.1 final
          log "=== cierre de la escalera ==="
          bash "$REPO_ROOT/scripts/verify-cilium-120-schema.sh" || FAIL "el esquema NO está listo para 4a"
          bash "$REPO_ROOT/scripts/witness-traffic.sh" stop
          stage_set final ;;

  status) echo "  cluster uid : $CUID"
          echo "  endpoint    : $APIEP"
          echo "  estado      : $STATE_DIR"
          echo "  stage       : $(stage_get)"
          echo "  last_sent   : $(cat "$STATE_DIR/last_sent" 2>/dev/null || echo '-')" ;;

  *) echo "uso: $0 {prepare|gate|v1.3.0|v1.4.1|v1.5.1|v1.6.1|final|status}" >&2; exit 2 ;;
esac
