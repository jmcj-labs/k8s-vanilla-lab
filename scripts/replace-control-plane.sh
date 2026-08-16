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
# The ceremony therefore:
#   1. Verifies at most ONE control plane is missing/unhealthy (never
#      replace two: with 3 members the quorum tolerates exactly one).
#   2. Renews the join material (certificate-key 2h + token 24h) unless
#      SKIP_RENEW=1 — the drill sets it to prove the expiry path.
#   3. Removes the dead etcd member and deletes the stale Node.
#   4. Recreates exactly that instance with `tofu apply -replace=...`
#      (NOT -target: a targeted apply would skip the target-group
#      attachment and leave the new node unregistered in the API endpoint).
#   5. Waits for the node to rejoin and closes with etcd 3/3 and API
#      targets 3/3 — capability restored, not merely survived.
#
# Requires: kubectl (admin kubeconfig), AWS credentials for the lab, and
# the tofu working dir initialised (make init).
set -euo pipefail

CP_INDEX="${1:?usage: replace-control-plane.sh <index>   (0..N)}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
TOFU_DIR="${TOFU_DIR:-tofu/envs/lab}"
SKIP_RENEW="${SKIP_RENEW:-0}"

log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }
command -v kubectl >/dev/null || FAIL "kubectl not found"
command -v aws >/dev/null || FAIL "aws CLI not found"
case "${CP_INDEX}" in ''|*[!0-9]*) FAIL "index must be a number (0..N)";; esac

T0=$(date -u +%s)
log "=== Replacing control plane index ${CP_INDEX} (cluster ${CLUSTER_NAME}) ==="

# ── 1. Only ONE replacement at a time ───────────────────────────────────────
# Count control-plane Nodes that are NOT Ready. Zero is fine (planned
# replacement of a healthy node); more than one means the quorum is already
# at its limit and adding churn would destroy it.
NOT_READY=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers \
  | awk '$2 != "Ready" {n++} END {print n+0}')
CP_TOTAL=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l | tr -d ' ')
log "control planes: ${CP_TOTAL} registered, ${NOT_READY} not Ready"
[ "${NOT_READY}" -le 1 ] || FAIL "${NOT_READY} control planes are not Ready — replacing now would break the quorum. Recover to 2/3 healthy first, or restore (docs/RUNBOOK-restore-etcd-ha.md)"

# ── 2. Identify the node being replaced, via providerID → instance id ───────
# providerID is the only reliable index→Node mapping (hostnames vary, tags
# live in EC2). The instance may already be terminated: query without a
# state filter so a shutting-down/terminated machine is still found.
OLD_INSTANCE=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=tag:Role,Values=control-plane" \
            "Name=tag:CPIndex,Values=${CP_INDEX}" \
  --query 'sort_by(Reservations[].Instances[], &LaunchTime)[-1].InstanceId' \
  --output text 2>/dev/null || echo "None")
log "instance carrying CPIndex=${CP_INDEX}: ${OLD_INSTANCE}"

OLD_NODE=""
if [ "${OLD_INSTANCE}" != "None" ] && [ -n "${OLD_INSTANCE}" ]; then
  OLD_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath="{range .items[?(@.spec.providerID)]}{.metadata.name}{'\t'}{.spec.providerID}{'\n'}{end}" \
    | grep "${OLD_INSTANCE}" | cut -f1 || true)
fi
log "Node object for that instance: ${OLD_NODE:-<none registered>}"

# A healthy CP to run etcdctl from — never the one being replaced.
SURVIVOR=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json | python3 -c "
import json,sys
old='''${OLD_NODE}'''.strip()
for n in json.load(sys.stdin)['items']:
    name=n['metadata']['name']
    if name==old: continue
    if any(c['type']=='Ready' and c['status']=='True' for c in n['status']['conditions']):
        print(name); break")
[ -n "${SURVIVOR}" ] || FAIL "no healthy control plane other than the one being replaced"
log "etcd operations will run on the survivor: ${SURVIVOR}"

etcdctl_on_survivor() {
  kubectl -n kube-system exec "etcd-${SURVIVOR}" -- etcdctl \
    --cacert /etc/kubernetes/pki/etcd/ca.crt \
    --cert /etc/kubernetes/pki/etcd/server.crt \
    --key /etc/kubernetes/pki/etcd/server.key \
    "$@"
}

# ── 3. Renew join material (unless the drill wants the expiry path) ─────────
if [ "${SKIP_RENEW}" = "1" ]; then
  log "SKIP_RENEW=1 — NOT renewing join material (drill: prove the expired-key path)"
else
  log "Renewing join material (certificate-key 2h + bootstrap token 24h)"
  CLUSTER_NAME="${CLUSTER_NAME}" AWS_REGION="${AWS_REGION}" \
    bash "$(dirname "$0")/renew-cp-certificate-key.sh" "${SURVIVOR}"
fi

# ── 4. Remove the dead etcd member and the stale Node ───────────────────────
# The member to remove is the one whose name matches the old Node. If the
# replacement is planned (node still healthy) it is removed anyway: the
# machine is about to disappear, and a member that never comes back is
# exactly what we are avoiding.
if [ -n "${OLD_NODE}" ]; then
  MEMBER_ID=$(etcdctl_on_survivor member list -w json 2>/dev/null | OLD="${OLD_NODE}" python3 -c "
import json,os,sys
old=os.environ['OLD']
for m in json.load(sys.stdin)['members']:
    if m.get('name')==old:
        print(format(m['ID'],'x')); break")
  if [ -n "${MEMBER_ID}" ]; then
    log "Removing etcd member ${OLD_NODE} (id ${MEMBER_ID})"
    etcdctl_on_survivor member remove "${MEMBER_ID}" >/dev/null
    log "✓ etcd member removed — membership is now $(etcdctl_on_survivor member list -w json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["members"]))')"
  else
    log "No etcd member named ${OLD_NODE} (already removed)"
  fi
  log "Deleting stale Node object ${OLD_NODE}"
  kubectl delete node "${OLD_NODE}" --ignore-not-found >/dev/null
else
  log "No Node object to clean up (instance never registered, or already deleted)"
fi

# ── 5. Recreate exactly that instance ───────────────────────────────────────
# -replace, NOT -target: a full plan with one resource replaced also
# rebuilds the target-group attachment (its target_id changes), so the new
# node is registered in the API endpoint. A -target apply would not.
ADDR="module.control_plane.aws_instance.control_plane[${CP_INDEX}]"
log "Recreating ${ADDR} (tofu apply -replace)"
( cd "${TOFU_DIR}" && tofu apply -auto-approve -replace="${ADDR}" ) \
  || FAIL "tofu apply -replace failed"
NEW_INSTANCE=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=tag:CPIndex,Values=${CP_INDEX}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
log "✓ new instance: ${NEW_INSTANCE}"

# ── 6. Wait for capability to be RESTORED (not merely for the box to boot) ──
log "Waiting for the replacement to join (bootstrap takes 8-12 min)..."
DEADLINE=$(( $(date -u +%s) + 1500 ))
until [ "$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null \
           | awk '$2 == "Ready" {n++} END {print n+0}')" -eq 3 ] \
   && [ "$(etcdctl_on_survivor member list -w json 2>/dev/null \
           | python3 -c 'import json,sys; m=json.load(sys.stdin)["members"]; print(len([x for x in m if x.get("clientURLs")]))' 2>/dev/null || echo 0)" -eq 3 ]; do
  [ "$(date -u +%s)" -lt "${DEADLINE}" ] || FAIL "replacement did not reach 3/3 nodes + 3/3 etcd members in 25 min (check /var/log/k8s-cp-bootstrap.log on ${NEW_INSTANCE})"
  sleep 30
done
log "✓ 3/3 control planes Ready · 3/3 etcd members started"

# Fresh deadline: the node-level wait may have consumed the previous one,
# and target health lags a joining node by a couple of health-check cycles.
TG_DEADLINE=$(( $(date -u +%s) + 300 ))
API_TG_ARN=$(aws elbv2 describe-target-groups --names "${CLUSTER_NAME}-api-tg" \
  --region "${AWS_REGION}" --query 'TargetGroups[0].TargetGroupArn' --output text)
until [ "$(aws elbv2 describe-target-health --target-group-arn "${API_TG_ARN}" --region "${AWS_REGION}" \
          | python3 -c 'import json,sys; t=json.load(sys.stdin)["TargetHealthDescriptions"]; print(len([d for d in t if d["TargetHealth"]["State"]=="healthy"]))')" -eq 3 ]; do
  [ "$(date -u +%s)" -lt "${TG_DEADLINE}" ] || FAIL "API target group did not reach 3/3 healthy in 5 min"
  sleep 15
done
T1=$(date -u +%s)
log "✓ API target group: 3/3 healthy"
log "=== Replacement complete in $((T1-T0))s — HA capacity RESTORED ==="
log "record the timing in docs/RUNBOOK-replace-control-plane.md"
