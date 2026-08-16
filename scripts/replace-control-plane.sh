#!/usr/bin/env bash
# Replace ONE control-plane node — the full ceremony (S2 piece 3, ADR-007).
#
# Usage: scripts/replace-control-plane.sh <index>          # 0, 1 or 2
#        SKIP_RENEW=1 scripts/replace-control-plane.sh <index>
#
# WHY A CEREMONY AND NOT JUST `tofu apply`: recreating the instance is the
# easy half. etcd remembers the DEAD member forever — bring a replacement
# up without removing it and the cluster ends with 4 members (3 alive, 1
# dead), which both fails the 3/3 smoke and, worse, moves the quorum
# threshold to 3: the NEXT single failure then takes the cluster down. The
# Node object of the old machine lingers too, NotReady, holding its taints.
#
# INVARIANT: exactly ONE control plane is replaced, and it is the one the
# operator named. Enforced by (a) an ATOMIC cluster-wide lock so two
# ceremonies cannot interleave, (b) an index-bound precondition, and (c) a
# SAVED PLAN that is inspected before being applied — never a bare
# `apply -replace`, which would also carry along whatever else was pending.
#
# ORDER MATTERS AND IS DELIBERATE: everything that can REFUSE the ceremony
# (preconditions, plan generation, plan inspection) runs BEFORE anything
# that degrades the cluster (member remove, node delete). A plan that turns
# out to be unacceptable must leave etcd at full strength — aborting after
# having already removed a member would hand the operator a 2-member
# cluster as the price of a failed dry run.
#
# Requires: kubectl (admin kubeconfig), AWS credentials for the lab, and
# the tofu working dir initialised (make init).
set -euo pipefail

CP_INDEX="${1:?usage: replace-control-plane.sh <index>   (0..N)}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
TOFU_DIR="${TOFU_DIR:-tofu/envs/lab}"
SKIP_RENEW="${SKIP_RENEW:-0}"
LOCK_CM="cp-replacement-lock"

log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }
command -v kubectl >/dev/null || FAIL "kubectl not found"
command -v aws >/dev/null || FAIL "aws CLI not found"
case "${CP_INDEX}" in ''|*[!0-9]*) FAIL "index must be a number (0..N)";; esac

T0=$(date -u +%s)
log "=== Replacing control plane index ${CP_INDEX} (cluster ${CLUSTER_NAME}) ==="

# ── 0. ATOMIC LOCK ──────────────────────────────────────────────────────────
# `kubectl create` on an existing object fails — the API server makes this
# mutually exclusive across shells, hosts and operators. Without it, two
# ceremonies could each observe a healthy cluster and each remove a member.
LOCK_OWNER="$(whoami)@$(hostname)-$$"
if ! kubectl -n kube-system create configmap "${LOCK_CM}" \
      --from-literal=owner="${LOCK_OWNER}" \
      --from-literal=index="${CP_INDEX}" \
      --from-literal=started="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1; then
  HOLDER=$(kubectl -n kube-system get configmap "${LOCK_CM}" \
    -o jsonpath='{.data.owner} (index {.data.index}, since {.data.started})' 2>/dev/null || echo "unknown")
  FAIL "another control-plane replacement is in flight: ${HOLDER}
  If it died, release the lock deliberately:
    kubectl -n kube-system delete configmap ${LOCK_CM}"
fi
PLAN_DIR=""
cleanup() {
  kubectl -n kube-system delete configmap "${LOCK_CM}" --ignore-not-found >/dev/null 2>&1 || true
  [ -n "${PLAN_DIR}" ] && rm -rf "${PLAN_DIR}"
  return 0
}
trap cleanup EXIT
log "✓ ceremony lock acquired (${LOCK_OWNER})"

# ── 1. Inventory: what SHOULD exist, what does, and in what shape ───────────
# How many control planes SHOULD exist is the yardstick for every check
# below — never guess it. `|| echo 3` would be the same fail-open pattern
# just removed from the state guard: inventing the expected size and then
# running a destructive ceremony against that invention.
set +e
CLUSTER_INFO=$(cd "${TOFU_DIR}" && tofu output -json cluster_info 2>&1)
CI_RC=$?
set -e
[ ${CI_RC} -eq 0 ] || FAIL "cannot read cluster_info from the tofu state (rc=${CI_RC}):
$(echo "${CLUSTER_INFO}" | sed 's/^/    /')
  The expected control-plane count is the yardstick for every safety check
  here — refusing to guess it. Usual causes: expired credentials, the
  working dir not initialised (make init), or an unreachable backend."
EXPECTED=$(echo "${CLUSTER_INFO}" | python3 -c '
import json,sys
print(json.load(sys.stdin)["control_plane_count"])' 2>/dev/null || echo "")
case "${EXPECTED}" in
  ''|*[!0-9]*) FAIL "control_plane_count missing or not a number in cluster_info" ;;
esac
[ "${EXPECTED}" -ge 3 ] || FAIL "control_plane_count is ${EXPECTED}: this ceremony assumes an HA cluster (>=3)"
[ "${CP_INDEX}" -lt "${EXPECTED}" ] || FAIL "index ${CP_INDEX} is out of range (cluster has ${EXPECTED} control planes)"

# Registered control-plane Nodes, with the instance id carried in providerID
NODES_JSON=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json)
NODE_TABLE=$(echo "${NODES_JSON}" | python3 -c '
import json,sys
for n in json.load(sys.stdin)["items"]:
    name=n["metadata"]["name"]
    pid=n["spec"].get("providerID","")
    inst=pid.rsplit("/",1)[-1] if pid else ""
    ready="Ready" if any(c["type"]=="Ready" and c["status"]=="True" for c in n["status"]["conditions"]) else "NotReady"
    print(f"{name}\t{inst}\t{ready}")')
NODE_TOTAL=$(echo "${NODE_TABLE}" | grep -c . || true)
NODE_READY=$(echo "${NODE_TABLE}" | awk -F'\t' '$3=="Ready"' | grep -c . || true)
log "control-plane Nodes: ${NODE_TOTAL} registered, ${NODE_READY} Ready (expected ${EXPECTED})"

# The instance currently carrying this index, from EC2 (terminated ones are
# still listed for a while) and, failing that, from the tofu state — the
# ceremony must KNOW which member it is burying, never skip it silently.
OLD_INSTANCE=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=tag:Role,Values=control-plane" \
            "Name=tag:CPIndex,Values=${CP_INDEX}" \
  --query 'sort_by(Reservations[].Instances[], &LaunchTime)[-1].InstanceId' \
  --output text 2>/dev/null || echo "None")
if [ "${OLD_INSTANCE}" = "None" ] || [ -z "${OLD_INSTANCE}" ]; then
  OLD_INSTANCE=$(cd "${TOFU_DIR}" && tofu show -json 2>/dev/null | IDX="${CP_INDEX}" python3 -c '
import json,os,sys
idx=int(os.environ["IDX"]); addr=f"module.control_plane.aws_instance.control_plane[{idx}]"
try: st=json.load(sys.stdin)
except Exception: sys.exit(0)
def walk(m):
    for r in m.get("resources",[]):
        if r.get("address")==addr: print(r["values"].get("id","")); return True
    for c in m.get("child_modules",[]):
        if walk(c): return True
    return False
walk(st.get("values",{}).get("root_module",{}))' || echo "")
  [ -n "${OLD_INSTANCE}" ] && log "instance id recovered from tofu state: ${OLD_INSTANCE}"
fi
log "instance carrying CPIndex=${CP_INDEX}: ${OLD_INSTANCE:-<none found>}"

OLD_NODE=""
OLD_NODE_STATE=""
if [ -n "${OLD_INSTANCE}" ] && [ "${OLD_INSTANCE}" != "None" ]; then
  OLD_NODE=$(echo "${NODE_TABLE}" | awk -F'\t' -v i="${OLD_INSTANCE}" '$2==i {print $1}')
  OLD_NODE_STATE=$(echo "${NODE_TABLE}" | awk -F'\t' -v i="${OLD_INSTANCE}" '$2==i {print $3}')
fi
log "Node for that instance: ${OLD_NODE:-<not registered>} ${OLD_NODE_STATE}"

# ── 2. Index-bound precondition ─────────────────────────────────────────────
# Only two shapes are safe, and both are tied to the index REQUESTED:
#   a) everything healthy (${EXPECTED}/${EXPECTED} Ready)  → planned replacement
#   b) exactly one control plane missing or NotReady, AND it is this index
# Everything else — two failures, or a request to replace a healthy node
# while another one is already down — would take the quorum with it.
UNHEALTHY=$(( EXPECTED - NODE_READY ))
if [ "${NODE_TOTAL}" -eq "${EXPECTED}" ] && [ "${NODE_READY}" -eq "${EXPECTED}" ]; then
  log "precondition: ${EXPECTED}/${EXPECTED} healthy — PLANNED replacement of index ${CP_INDEX}"
elif [ "${UNHEALTHY}" -eq 1 ]; then
  # The single casualty must be exactly the index we were asked to replace:
  # either its Node is NotReady, or it has no Node at all (machine gone).
  if [ "${OLD_NODE_STATE}" = "Ready" ]; then
    FAIL "one control plane is down, but index ${CP_INDEX} is HEALTHY. Replacing it would leave the cluster with 1/${EXPECTED} — recover or replace the failed one instead"
  fi
  log "precondition: ${NODE_READY}/${EXPECTED} healthy and index ${CP_INDEX} is the casualty — RECOVERY replacement"
else
  FAIL "${UNHEALTHY} control planes are unhealthy/absent (expected at most 1). Replacing now would break the quorum — recover to ${EXPECTED}/${EXPECTED} or restore (docs/RUNBOOK-restore-etcd-ha.md)"
fi

# A healthy CP to run etcdctl from — never the one being replaced.
SURVIVOR=$(echo "${NODE_TABLE}" | awk -F'\t' -v old="${OLD_NODE}" '$3=="Ready" && $1!=old {print $1; exit}')
[ -n "${SURVIVOR}" ] || FAIL "no healthy control plane other than the one being replaced"
log "etcd operations will run on the survivor: ${SURVIVOR}"

etcdctl_on_survivor() {
  kubectl -n kube-system exec "etcd-${SURVIVOR}" -- etcdctl \
    --cacert /etc/kubernetes/pki/etcd/ca.crt \
    --cert /etc/kubernetes/pki/etcd/server.crt \
    --key /etc/kubernetes/pki/etcd/server.key \
    "$@"
}
etcd_members_json() { etcdctl_on_survivor member list -w json 2>/dev/null; }

# ── 3. PLAN AND INSPECT FIRST — before degrading anything ───────────────────
# Everything that can still say NO happens here, while etcd is at full
# strength. `apply -replace` alone would also carry along whatever else was
# pending or drifted, so: plan to a file, prove on the JSON that no other
# instance is destroyed or replaced, and later apply THAT saved plan.
ADDR="module.control_plane.aws_instance.control_plane[${CP_INDEX}]"
PLAN_DIR=$(mktemp -d)
PLAN_FILE="${PLAN_DIR}/tfplan"
log "Planning the replacement of ${ADDR} (nothing has been touched yet)"
( cd "${TOFU_DIR}" && tofu plan -input=false -replace="${ADDR}" -out="${PLAN_FILE}" >/dev/null ) \
  || FAIL "tofu plan failed — cluster untouched, etcd still at full strength"

( cd "${TOFU_DIR}" && tofu show -json "${PLAN_FILE}" ) | ADDR="${ADDR}" python3 -c '
import json,os,sys
target=os.environ["ADDR"]
plan=json.load(sys.stdin)
bad=[]; expected=False
for c in plan.get("resource_changes",[]):
    actions=c.get("change",{}).get("actions",[])
    destructive = "delete" in actions
    addr = c["address"]
    if addr==target:
        expected = destructive and "create" in actions
        continue
    if destructive and c["type"] == "aws_instance":
        bad.append(addr + ": " + ",".join(actions))
if bad:
    print("PLAN TOUCHES OTHER INSTANCES:")
    for b in bad: print("   ", b)
    sys.exit(2)
if not expected:
    print("plan does NOT replace " + target)
    sys.exit(3)
print("plan verified: only the target control plane is replaced")' \
  || FAIL "plan inspection refused this plan (see above) — NOTHING was applied and the cluster is untouched: etcd still has all its members and no Node was deleted"
log "✓ plan inspected and saved: only ${ADDR} is replaced"

# ── 4. Renew join material (unless the drill wants the expiry path) ─────────
if [ "${SKIP_RENEW}" = "1" ]; then
  log "SKIP_RENEW=1 — NOT renewing join material (drill: prove the expired-key path)"
else
  log "Renewing join material (certificate-key 2h + bootstrap token 24h)"
  CLUSTER_NAME="${CLUSTER_NAME}" AWS_REGION="${AWS_REGION}" \
    bash "$(dirname "$0")/renew-cp-certificate-key.sh" "${SURVIVOR}"
fi

# ── 5. Bury the dead: etcd member + Node ────────────────────────────────────
# FROM HERE ON the cluster is degraded on purpose: the plan is already
# approved and saved, so every remaining step moves towards restoring it.
# The member is identified by name when the Node is known; when the Node is
# already gone, by ELIMINATION — the member whose name matches no current
# control-plane Node. More than one orphan is a multi-failure scenario, not
# a replacement, and aborts.
LIVE_NODE_NAMES=$(echo "${NODE_TABLE}" | cut -f1)
MEMBER_ID=""
MEMBER_NAME=""
if [ -n "${OLD_NODE}" ]; then
  MEMBER_NAME="${OLD_NODE}"
else
  ORPHANS=$(etcd_members_json | LIVE="${LIVE_NODE_NAMES}" python3 -c '
import json,os,sys
live={l.strip() for l in os.environ["LIVE"].splitlines() if l.strip()}
for m in json.load(sys.stdin)["members"]:
    if m.get("name") and m["name"] not in live: print(m["name"])')
  ORPHAN_COUNT=$(echo "${ORPHANS}" | grep -c . || true)
  if [ "${ORPHAN_COUNT}" -gt 1 ]; then
    FAIL "more than one etcd member has no Node (${ORPHANS//$'\n'/, }) — this is a multi-failure, not a replacement"
  fi
  MEMBER_NAME=$(echo "${ORPHANS}" | head -1)
  [ -n "${MEMBER_NAME}" ] && log "orphan etcd member identified by elimination: ${MEMBER_NAME}"
fi

if [ -n "${MEMBER_NAME}" ]; then
  MEMBER_ID=$(etcd_members_json | NAME="${MEMBER_NAME}" python3 -c '
import json,os,sys
name=os.environ["NAME"]
for m in json.load(sys.stdin)["members"]:
    if m.get("name")==name: print(format(m["ID"],"x")); break')
fi
if [ -n "${MEMBER_ID}" ]; then
  log "Removing etcd member ${MEMBER_NAME} (id ${MEMBER_ID})"
  etcdctl_on_survivor member remove "${MEMBER_ID}" >/dev/null
  log "✓ membership now: $(etcd_members_json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["members"]))') members"
else
  log "No etcd member to remove for index ${CP_INDEX} (already removed, or never joined)"
fi
if [ -n "${OLD_NODE}" ]; then
  log "Deleting stale Node ${OLD_NODE}"
  kubectl delete node "${OLD_NODE}" --ignore-not-found >/dev/null
fi

# ── 6. Apply the plan approved in step 3 ────────────────────────────────────
# The saved plan is applied verbatim: what was inspected is what runs.
log "Applying the approved plan (${ADDR})"
( cd "${TOFU_DIR}" && tofu apply -input=false "${PLAN_FILE}" ) || FAIL "tofu apply failed"

# The old kubelet can re-register its Node between our delete and the actual
# termination of the machine — delete again now that the instance is gone.
if [ -n "${OLD_NODE}" ]; then
  kubectl delete node "${OLD_NODE}" --ignore-not-found >/dev/null 2>&1 || true
fi

# ── 6. Close on capacity RESTORED, with EXACT sets (smoke §14 invariants) ───
log "Waiting for the replacement to join (bootstrap takes 8-12 min)..."
DEADLINE=$(( $(date -u +%s) + 1800 ))
while true; do
  NT=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | grep -c . || true)
  NR=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | awk '$2=="Ready"' | grep -c . || true)
  MEM=$(etcd_members_json | python3 -c '
import json,sys
m=json.load(sys.stdin)["members"]
started=[x for x in m if x.get("clientURLs")]
print(len(m), len(started))' 2>/dev/null || echo "0 0")
  MEM_TOTAL=${MEM% *}; MEM_STARTED=${MEM#* }
  if [ "${NT}" -eq "${EXPECTED}" ] && [ "${NR}" -eq "${EXPECTED}" ] \
     && [ "${MEM_TOTAL}" -eq "${EXPECTED}" ] && [ "${MEM_STARTED}" -eq "${EXPECTED}" ]; then
    break
  fi
  [ "$(date -u +%s)" -lt "${DEADLINE}" ] \
    || FAIL "not restored in 30 min (Nodes ${NR}/${NT}, etcd ${MEM_STARTED}/${MEM_TOTAL}) — check /var/log/k8s-cp-bootstrap.log on the new instance"
  sleep 30
done
log "✓ exactly ${EXPECTED} control-plane Nodes, all Ready · exactly ${EXPECTED} etcd members, all started"

# etcd endpoint health across the whole cluster, not just membership shape
etcdctl_on_survivor endpoint health --cluster >/dev/null 2>&1 \
  || FAIL "etcd endpoint health failed after the replacement"
log "✓ etcd endpoint health: all endpoints healthy"

# API target set must equal EXACTLY the live control-plane instance IDs
API_TG_ARN=$(aws elbv2 describe-target-groups --names "${CLUSTER_NAME}-api-tg" \
  --region "${AWS_REGION}" --query 'TargetGroups[0].TargetGroupArn' --output text)
CP_IDS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=tag:Role,Values=control-plane" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | sort)
# TWO separate assertions, because "3 healthy" hides a 4th target left
# draining or unhealthy from the machine we just replaced:
#   (a) the REGISTERED set equals exactly the live control planes
#   (b) every one of them is healthy
TG_DEADLINE=$(( $(date -u +%s) + 600 ))
while true; do
  TARGETS_JSON=$(aws elbv2 describe-target-health --target-group-arn "${API_TG_ARN}" --region "${AWS_REGION}")
  ALL_IDS=$(echo "${TARGETS_JSON}" | python3 -c '
import json,sys
t=json.load(sys.stdin)["TargetHealthDescriptions"]
print("\n".join(sorted(d["Target"]["Id"] for d in t)))')
  UNHEALTHY_LIST=$(echo "${TARGETS_JSON}" | python3 -c '
import json,sys
t=json.load(sys.stdin)["TargetHealthDescriptions"]
print("\n".join(d["Target"]["Id"] + "=" + d["TargetHealth"]["State"]
                for d in t if d["TargetHealth"]["State"] != "healthy"))')
  if [ "${ALL_IDS}" = "${CP_IDS}" ] && [ -z "${UNHEALTHY_LIST}" ]; then
    break
  fi
  [ "$(date -u +%s)" -lt "${TG_DEADLINE}" ] \
    || FAIL "API target group did not settle in 10 min
  registered: ${ALL_IDS//$'\n'/ }
  live CPs:   ${CP_IDS//$'\n'/ }
  not healthy: ${UNHEALTHY_LIST//$'\n'/ }"
  sleep 15
done
T1=$(date -u +%s)
log "✓ API target group: registered set == exactly the ${EXPECTED} live control planes, ALL healthy (no stale/draining target)"
log "=== Replacement complete in $((T1-T0))s — HA capacity RESTORED ==="
log "record the timing in docs/RUNBOOK-replace-control-plane.md"
