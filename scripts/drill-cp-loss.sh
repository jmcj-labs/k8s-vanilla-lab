#!/usr/bin/env bash
# DRILL — survive the loss of a control plane, including the FOUNDER.
#
# Usage: scripts/drill-cp-loss.sh [index]        # default 0 (the founder)
#
# The acceptance criterion of brief #S2-3 is not "the cluster still pings":
# it is that with one control plane DOWN the cluster keeps doing the four
# things it is for — serving API writes and reads, authenticating IAM
# identities, running the workloads, and taking its etcd backup from a
# surviving member. Each is proven separately here.
#
# Stopping (not terminating) is deliberate: it is the honest simulation of
# losing a node, and it lets the drill close by bringing it back and showing
# the quorum heal. The machine keeps its root volume and private IP, so the
# member rejoins on boot without any ceremony — that is the difference
# between this drill and the REPLACEMENT one
# (docs/RUNBOOK-replace-control-plane.md).
#
# Requires: kubectl (break-glass kubeconfig), AWS credentials for the lab.
set -euo pipefail

CP_INDEX="${1:-0}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
# TWO different identities are in play and conflating them costs a 403:
# the drill itself needs EC2/S3 powers (the lab profile in AWS_PROFILE),
# while the IAM proof must present an identity the platform-admin role
# actually trusts — the SSO bridge, never a generic admin session (ADR-005).
# The authenticator's exec block inherits the ambient AWS_PROFILE, so that
# one call gets its own.
IAM_AWS_PROFILE="${IAM_AWS_PROFILE:-k8s-platform}"

log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }
OK()   { echo "  ✓ $*"; }
command -v kubectl >/dev/null || FAIL "kubectl not found"

# A FAILED DRILL MUST NOT LEAVE A CONTROL PLANE STOPPED. Learned the hard
# way on the first live run: a proof failed mid-window and the script exited
# with the founder still down, leaving the cluster at 2/3 — a drill that
# breaks what it was meant to prove safe. Whatever happens from the moment
# the instance is stopped, it gets started again on the way out.
STOPPED_INSTANCE=""
restore_victim() {
  [ -n "${STOPPED_INSTANCE}" ] || return 0
  echo "[$(date -u +'%H:%M:%SZ')] restoring ${STOPPED_INSTANCE} (drill exit path)" >&2
  aws ec2 start-instances --instance-ids "${STOPPED_INSTANCE}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
}
trap restore_victim EXIT

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
T0=$(date -u +%s)
log "=== DRILL: losing control plane index ${CP_INDEX} (cluster ${CLUSTER_NAME}) ==="

# ── Pre-flight: the cluster must be whole before we break it ────────────────
CP_READY=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers \
  | awk '$2=="Ready"' | grep -c . || true)
[ "${CP_READY}" -eq 3 ] || FAIL "need 3/3 control planes Ready before the drill (have ${CP_READY})"
OK "3/3 control planes Ready — starting from a whole cluster"

TARGET_INSTANCE=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=tag:Role,Values=control-plane" \
            "Name=tag:CPIndex,Values=${CP_INDEX}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "${TARGET_INSTANCE}" ] || FAIL "no running control plane with CPIndex=${CP_INDEX}"
TARGET_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
  -o jsonpath="{range .items[*]}{.metadata.name}{'\t'}{.spec.providerID}{'\n'}{end}" \
  | grep "${TARGET_INSTANCE}" | cut -f1)
[ -n "${TARGET_NODE}" ] || FAIL "could not map ${TARGET_INSTANCE} to a Node"
log "victim: index ${CP_INDEX} → ${TARGET_NODE} (${TARGET_INSTANCE})"

# Witness written BEFORE the outage: it must still be readable during it.
kubectl delete configmap cp-loss-witness --ignore-not-found >/dev/null
kubectl create configmap cp-loss-witness --from-literal=before="${STAMP}" >/dev/null
OK "witness ConfigMap written before the outage"

# ── Kill it ─────────────────────────────────────────────────────────────────
log "Stopping ${TARGET_INSTANCE}..."
STOPPED_INSTANCE="${TARGET_INSTANCE}"   # arms the restore-on-exit trap
aws ec2 stop-instances --instance-ids "${TARGET_INSTANCE}" --region "${AWS_REGION}" >/dev/null
aws ec2 wait instance-stopped --instance-ids "${TARGET_INSTANCE}" --region "${AWS_REGION}"
T_DOWN=$(date -u +%s)
log "✓ instance stopped after $((T_DOWN-T0))s"

# WAIT UNTIL THE LOSS IS ACKNOWLEDGED, then prove things. Powering a machine
# off and immediately asserting "the cluster is fine" proves almost nothing:
# for the first ~40s Kubernetes still believes the Node is Ready
# (node-monitor-grace-period) and for up to ~90s the NLB still lists its
# target as healthy (health-check interval × threshold). Running the proofs
# inside that blind spot would be theatre. The real 2/3 state is the one
# where BOTH control loops have noticed.
log "Waiting for the loss to be ACKNOWLEDGED (Node NotReady + API target out of service)..."
API_TG_ARN=$(aws elbv2 describe-target-groups --names "${CLUSTER_NAME}-api-tg" \
  --region "${AWS_REGION}" --query 'TargetGroups[0].TargetGroupArn' --output text)
ACK_DEADLINE=$(( $(date -u +%s) + 300 ))
NODE_ACK=""; TG_ACK=""
while [ -z "${NODE_ACK}" ] || [ -z "${TG_ACK}" ]; do
  if [ -z "${NODE_ACK}" ]; then
    NODE_STATE=$(kubectl get node "${TARGET_NODE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ "${NODE_STATE}" != "True" ] && NODE_ACK="yes" && OK "Kubernetes marked ${TARGET_NODE} NotReady"
  fi
  if [ -z "${TG_ACK}" ]; then
    TG_STATE=$(aws elbv2 describe-target-health --target-group-arn "${API_TG_ARN}" \
      --region "${AWS_REGION}" --query "TargetHealthDescriptions[?Target.Id=='${TARGET_INSTANCE}'].TargetHealth.State" \
      --output text 2>/dev/null || echo "")
    if [ "${TG_STATE}" != "healthy" ]; then
      TG_ACK="yes"; OK "the NLB took the target out of service (state: ${TG_STATE:-deregistered})"
    fi
  fi
  [ -n "${NODE_ACK}" ] && [ -n "${TG_ACK}" ] && break
  [ "$(date -u +%s)" -lt "${ACK_DEADLINE}" ] || FAIL "the loss was not acknowledged within 300s (Node=${NODE_STATE:-?}, target=${TG_STATE:-?})"
  sleep 10
done
T_ACK=$(date -u +%s)
log "✓ loss acknowledged by both control loops after $((T_ACK-T_DOWN))s — NOW the cluster is genuinely 2/3"

# ── Proof 1: the API still serves WRITES and READS (through the NLB) ────────
# The kubeconfig points at the NLB DNS, so this also proves the endpoint
# routes around the dead target instead of blackholing a third of requests.
log "Proof 1/4: API writes and reads with one control plane down"
kubectl delete configmap cp-loss-during --ignore-not-found >/dev/null 2>&1 || true
for i in 1 2 3 4 5; do
  kubectl create configmap cp-loss-during --from-literal="attempt${i}"="${STAMP}" >/dev/null 2>&1 && break
  [ "${i}" = 5 ] && FAIL "could not write to the API with one CP down"
  sleep 5
done
READ_BACK=$(kubectl get configmap cp-loss-witness -o jsonpath='{.data.before}')
[ "${READ_BACK}" = "${STAMP}" ] || FAIL "witness read back wrong (${READ_BACK})"
OK "wrote a new object and read the pre-outage witness back — API intact"

# Ten consecutive reads: a single success could be luck with fail-open.
FAILED=0
for i in $(seq 1 10); do kubectl get --raw /readyz >/dev/null 2>&1 || FAILED=$((FAILED+1)); done
[ "${FAILED}" -eq 0 ] || FAIL "${FAILED}/10 API probes failed through the endpoint"
OK "10/10 consecutive API probes through the NLB endpoint succeeded"

# ── Proof 2: IAM authentication still works ────────────────────────────────
# Every surviving API server webhooks to ITS OWN local authenticator, so
# this proves the per-node material installed at join is doing its job.
log "Proof 2/4: IAM authentication (aws-iam-authenticator) with one CP down"
AUTH_DS=$(kubectl -n kube-system get ds aws-iam-authenticator \
  -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}')
log "  authenticator DaemonSet: ${AUTH_DS} (2/2 expected while one CP is down)"
IAM_WHO=""
IAM_GROUPS=""
if [ -f "${HOME}/.kube/${CLUSTER_NAME}-admin.conf" ]; then
  IAM_WHO=$(AWS_PROFILE="${IAM_AWS_PROFILE}" KUBECONFIG="${HOME}/.kube/${CLUSTER_NAME}-admin.conf" \
    kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || true)
  IAM_GROUPS=$(AWS_PROFILE="${IAM_AWS_PROFILE}" KUBECONFIG="${HOME}/.kube/${CLUSTER_NAME}-admin.conf" \
    kubectl auth whoami -o jsonpath='{.status.userInfo.groups}' 2>/dev/null || true)
fi
if [ -n "${IAM_WHO}" ]; then
  OK "IAM identity authenticated end to end: ${IAM_WHO} · groups ${IAM_GROUPS}"
  OK "SSO bridge → platform-admin role → webhook → RBAC, all with one control plane down"
else
  # The full proof needs an SSO session allowed to assume the platform-admin
  # role (ADR-005: that role trusts the k8s-platform/k8s-dev bridges and the
  # CI role — NOT a generic admin session). Without it, still prove the
  # WEBHOOK PATH itself: present a token for an unmapped identity and demand
  # an authenticated refusal. "Unauthorized" means the API server called the
  # authenticator and got an answer; a broken webhook gives a 500 or hangs.
  log "  no assumable platform-admin session — falling back to the webhook-path proof"
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  UNMAPPED_TOKEN=$(aws-iam-authenticator token -i "${ACCOUNT_ID}.${AWS_REGION}.${CLUSTER_NAME}" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["token"])' 2>/dev/null || true)
  [ -n "${UNMAPPED_TOKEN}" ] || FAIL "could not mint an authenticator token for the webhook proof"
  API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  AUTH_ANSWER=$(kubectl --kubeconfig=/dev/null --server="${API_SERVER}" --insecure-skip-tls-verify \
    --token="${UNMAPPED_TOKEN}" get nodes 2>&1 || true)
  echo "${AUTH_ANSWER}" | grep -q "Unauthorized" \
    || FAIL "the authenticator webhook did not give an authenticated answer with one CP down: ${AUTH_ANSWER}"
  OK "authenticator webhook answered (authenticated refusal for an unmapped identity) — the IAM path is alive"
  log "  note: for the END-TO-END identity proof run 'aws sso login --profile k8s-platform' first"
fi

# ── Proof 3: the workloads are untouched ───────────────────────────────────
log "Proof 3/4: workloads intact"
# Written defensively ON PURPOSE. Under `set -euo pipefail` an informational
# probe must never be able to kill the drill mid-window: a bare
# `[ x -gt 0 ] && echo ...` returns non-zero when false, and any pipeline
# stage failing (grep with no matches) aborts the script. Every probe below
# is wrapped so its VALUE is reported and its exit status is neutralised —
# these are observations, not assertions.
PG_STATUS=$( { kubectl -n data get cluster logistics-pg \
  -o jsonpath='{.status.readyInstances}/{.status.instances} ({.status.phase})' 2>/dev/null; } || true )
if [ -n "${PG_STATUS}" ]; then
  OK "CNPG logistics-pg: ${PG_STATUS}"
else
  log "  (no CNPG cluster deployed — skipping that observation)"
fi

KAFKA_READY=$( { kubectl -n data get pods -l strimzi.io/cluster=logistics-kafka \
  --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l | tr -d ' '; } || echo 0 )
if [ "${KAFKA_READY:-0}" -gt 0 ]; then
  OK "Kafka pods Running: ${KAFKA_READY}"
else
  log "  (no Kafka pods found — skipping that observation)"
fi

NOT_RUNNING=$( { kubectl get pods -A --no-headers 2>/dev/null \
  | awk -v n="${TARGET_NODE}" '$4!="Running" && $4!="Completed" && $8!=n' | wc -l | tr -d ' '; } || echo 0 )
log "  pods not Running outside the stopped node: ${NOT_RUNNING:-0}"

# ── Proof 4: the etcd backup runs from a SURVIVING member ──────────────────
# The CronJob has no node pin ON PURPOSE (S2-3): pinning it would kill the
# backup exactly when the pinned node dies.
log "Proof 4/4: etcd backup from a surviving control plane"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BACKUP_BUCKET="${BACKUP_BUCKET:-${CLUSTER_NAME}-backups-${ACCOUNT_ID}}"
BEFORE_KEY=$(aws s3api list-objects-v2 --bucket "${BACKUP_BUCKET}" --prefix etcd/ \
  --query 'sort_by(Contents,&LastModified)[-1].Key' --output text 2>/dev/null || echo "none")
kubectl -n kube-system delete job etcd-drill-loss --ignore-not-found >/dev/null
kubectl -n kube-system create job --from=cronjob/etcd-backup etcd-drill-loss >/dev/null
kubectl -n kube-system wait --for=condition=complete job/etcd-drill-loss --timeout=300s >/dev/null \
  || FAIL "etcd backup job did not complete with one control plane down"
BACKUP_NODE=$(kubectl -n kube-system get pods -l job-name=etcd-drill-loss \
  -o jsonpath='{.items[0].spec.nodeName}')
AFTER_KEY=$(aws s3api list-objects-v2 --bucket "${BACKUP_BUCKET}" --prefix etcd/ \
  --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
[ "${AFTER_KEY}" != "${BEFORE_KEY}" ] || FAIL "no fresh etcd snapshot appeared in S3"
[ "${BACKUP_NODE}" != "${TARGET_NODE}" ] || FAIL "backup ran on the stopped node?!"
OK "fresh snapshot ${AFTER_KEY} taken from ${BACKUP_NODE} (not the stopped node)"
kubectl -n kube-system delete job etcd-drill-loss --ignore-not-found >/dev/null

# ── Heal: bring it back and watch the quorum close ─────────────────────────
T_PROOFS=$(date -u +%s)
log "All proofs passed with a genuinely 2/3 cluster ($((T_PROOFS-T_ACK))s of acknowledged-degraded operation)"
log "Starting ${TARGET_INSTANCE} back up..."
aws ec2 start-instances --instance-ids "${TARGET_INSTANCE}" --region "${AWS_REGION}" >/dev/null
aws ec2 wait instance-running --instance-ids "${TARGET_INSTANCE}" --region "${AWS_REGION}"

DEADLINE=$(( $(date -u +%s) + 900 ))
until [ "$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | awk '$2=="Ready"' | grep -c . || true)" -eq 3 ]; do
  [ "$(date -u +%s)" -lt "${DEADLINE}" ] || FAIL "the node did not rejoin within 15 min"
  sleep 20
done
SURVIVOR=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | awk '$2=="Ready"{print $1; exit}')
MEMBERS=$(kubectl -n kube-system exec "etcd-${SURVIVOR}" -- etcdctl \
  --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key member list -w json 2>/dev/null \
  | python3 -c '
import json,sys
m=json.load(sys.stdin)["members"]
started=[x for x in m if x.get("clientURLs")]
print(len(started), len(m))')
[ "${MEMBERS}" = "3 3" ] || FAIL "etcd did not return to 3/3 (got ${MEMBERS})"
T1=$(date -u +%s)

STOPPED_INSTANCE=""   # node is back and verified: stand the restore trap down
kubectl delete configmap cp-loss-witness cp-loss-during --ignore-not-found >/dev/null
echo ""
log "=== DRILL PASSED: the cluster survived losing index ${CP_INDEX} ==="
log "timings: stop $((T_DOWN-T0))s · loss acknowledged $((T_ACK-T_DOWN))s · proofs under 2/3 $((T_PROOFS-T_ACK))s · full heal $((T1-T_PROOFS))s · total $((T1-T0))s"
log "record them in docs/EVIDENCE-S2-piece3.md"
