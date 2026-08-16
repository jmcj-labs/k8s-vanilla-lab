#!/usr/bin/env bash
# etcd restore DRILL — HA edition (3 CPs, stacked etcd), over SSM Run Command.
# The full ceremony from docs/RUNBOOK-restore-etcd-ha.md, executable end to end.
#
# NATURE OF THE BEAST: an HA restore is the RECONSTRUCTION OF A NEW LOGICAL
# CLUSTER — stop all three control planes, wipe membership and data dirs,
# restore the snapshot on ONE member with `etcdutl` using --bump-revision +
# --mark-compacted (etcd 3.6's express recommendation: it invalidates every
# controller/watch cache left from the old incarnation), then re-join the
# other two with `etcdctl member add`, ONE AT A TIME.
#
# ORCHESTRATION IS OUT-OF-BAND, NOT kubectl: in the real scenario the API is
# down — that is the point. Since INCIDENTS #16 the channel is SSM Run
# Command (root, no SSH, no key to lose, audited), not SSH. kubectl only
# opens (witness + snapshot trigger) and closes (witness recovered) the drill.
#
# REENTRANT: every phase publishes a marker in SSM, so a ceremony interrupted
# after the data dirs are set aside — the point of no easy return — resumes
# instead of restarting. The lock also lives in SSM: a ConfigMap cannot
# arbitrate mutual exclusion when the API it lives in is dead.
#
# Requires: kubectl (break-glass kubeconfig) for the opening/closing phases,
# and operator credentials able to SendCommand + presign S3 (the CP role is
# write-only to etcd/* by design and is not widened for drills).
# API DOWNTIME for the whole ceremony — run it knowingly.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
TOFU_DIR="${TOFU_DIR:-tofu/envs/lab}"
ETCD_VER="${ETCD_VER:-v3.6.6}"   # must match the running etcd image
BUMP_REVISION=1000000000
LOCK_PARAM="/k8s/${CLUSTER_NAME}/oob/restore-lock"
PHASE_PARAM="/k8s/${CLUSTER_NAME}/oob/restore-phase"
STATE_PARAM="/k8s/${CLUSTER_NAME}/oob/restore-state"

log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }
OK()   { echo "  ✓ $*"; }
command -v kubectl >/dev/null || FAIL "kubectl not found"
command -v aws >/dev/null || FAIL "aws CLI not found"
command -v jq >/dev/null || FAIL "jq not found"

# shellcheck source=scripts/lib/ssm-exec.sh
. "$(dirname "$0")/lib/ssm-exec.sh"

# ── Lock and phase bookkeeping (both in SSM, both survive a dead laptop) ────
LOCK_HELD=""
cleanup() {
  ssm_cancel_inflight
  if [ -n "${LOCK_HELD}" ]; then
    echo "[$(date -u +'%H:%M:%SZ')] NOTE: the ceremony lock is still held on purpose." >&2
    echo "  Resume with:  bash $0" >&2
    echo "  Abandon with: aws ssm delete-parameter --name ${LOCK_PARAM} --region ${AWS_REGION}" >&2
  fi
}
trap cleanup EXIT
trap 'echo; echo "interrupted — cancelling in-flight commands"; ssm_cancel_inflight; exit 130' INT TERM

phase_done() { aws ssm put-parameter --name "${PHASE_PARAM}" --type String --overwrite \
                 --value "$1" --region "${AWS_REGION}" >/dev/null; }
phase_get()  { aws ssm get-parameter --name "${PHASE_PARAM}" --query Parameter.Value \
                 --output text --region "${AWS_REGION}" 2>/dev/null || echo "none"; }
state_put()  { aws ssm put-parameter --name "${STATE_PARAM}" --type String --overwrite \
                 --value "$1" --region "${AWS_REGION}" >/dev/null; }
state_get()  { aws ssm get-parameter --name "${STATE_PARAM}" --query Parameter.Value \
                 --output text --region "${AWS_REGION}" 2>/dev/null || echo ""; }

# Phases in order. `after <phase>` answers "is that phase already complete?"
# and MUST be an index comparison: an earlier attempt walked the list setting
# a flag when it met the completed phase, which — since "none" leads the list
# — made every phase look done and skipped the whole ceremony. Harmless that
# time (it aborted at the verification with the cluster untouched), lethal in
# a real resume, where it would skip phases that never happened.
PHASES="none witness snapshot stopped datadirs restored cp0up cp1 cp2 verified"
DONE_PHASE=$(phase_get)
phase_index() {
  local want="$1" i=0 p
  for p in ${PHASES}; do
    [ "${p}" = "${want}" ] && { echo "${i}"; return 0; }
    i=$((i + 1))
  done
  echo "-1"
}
after() {
  local ti di
  ti=$(phase_index "$1")
  di=$(phase_index "${DONE_PHASE}")
  [ "${ti}" -ge 0 ] || FAIL "unknown phase '$1'"
  [ "${di}" -ge 0 ] || FAIL "unrecognised recorded phase '${DONE_PHASE}' — inspect ${PHASE_PARAM}"
  [ "${di}" -ge "${ti}" ]
}

# ── Acquire the lock (atomic: put-parameter without --overwrite) ────────────
LOCK_OWNER="$(whoami)@$(hostname)-$$"
if ! aws ssm put-parameter --name "${LOCK_PARAM}" --type String \
       --value "${LOCK_OWNER} started $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --region "${AWS_REGION}" >/dev/null 2>&1; then
  HOLDER=$(aws ssm get-parameter --name "${LOCK_PARAM}" --query Parameter.Value \
             --output text --region "${AWS_REGION}" 2>/dev/null || echo "unknown")
  if [ "${DONE_PHASE}" = "none" ]; then
    FAIL "another HA restore is in flight: ${HOLDER}
  If it died before doing anything, release it:
    aws ssm delete-parameter --name ${LOCK_PARAM} --region ${AWS_REGION}"
  fi
  log "RESUMING an interrupted ceremony (lock: ${HOLDER}, last completed phase: ${DONE_PHASE})"
fi
LOCK_HELD="yes"

T0=$(date -u +%s)
log "=== DRILL: HA etcd restore over SSM Run Command (cluster ${CLUSTER_NAME}) ==="

# ── Inventory by CP index, from EC2 tags (never from a node list: the API
#    will be dead for most of this ceremony) ─────────────────────────────────
declare -a CP_ID CP_PRIV CP_NAME
for i in 0 1 2; do
  read -r CP_ID[$i] CP_PRIV[$i] <<<"$(aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
              "Name=tag:Role,Values=control-plane" \
              "Name=tag:CPIndex,Values=${i}" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress]' --output text)"
  [ -n "${CP_ID[$i]}" ] || FAIL "no running control plane with CPIndex=${i}"
done

# ── PREFLIGHT: prove the channel BEFORE touching anything ──────────────────
# The whole reason this piece exists is that a recovery path depended on an
# access nobody had ever exercised. Never again: if the door does not open
# now, the ceremony stops here with the cluster untouched.
if ! after witness; then
  log "Preflight: proving out-of-band access to all three control planes"
  for i in 0 1 2; do
    ssm_online "${CP_ID[$i]}" || FAIL "CP-${i} (${CP_ID[$i]}) is not Online in SSM — refusing to start"
    ssm_canary "${CP_ID[$i]}" || FAIL "canary Run Command failed on CP-${i} (${CP_ID[$i]}) — refusing to start"
    CP_NAME[$i]=$(ssm_run "${CP_ID[$i]}" 'hostname' | tr -d '[:space:]')
    [ -n "${CP_NAME[$i]}" ] || FAIL "could not read hostname of CP-${i}"
    OK "CP-${i}: ${CP_NAME[$i]} (${CP_ID[$i]}, ${CP_PRIV[$i]}) — channel proven"
  done
else
  for i in 0 1 2; do CP_NAME[$i]=$(ssm_run "${CP_ID[$i]}" 'hostname' | tr -d '[:space:]'); done
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BACKUP_BUCKET="${BACKUP_BUCKET:-${CLUSTER_NAME}-backups-${ACCOUNT_ID}}"

# ── Phase 1: witness, snapshot, ANTI-witness ───────────────────────────────
# The anti-witness is what turns this from a smoke into a proof: an object
# created AFTER the snapshot, which must be GONE afterwards. Without it,
# "the witness is back" is also what you would see if nothing happened.
if after snapshot; then
  read -r STAMP SNAP <<<"$(state_get)"
  # A resume without the witness/snapshot it is resuming FROM is not a
  # resume: proceeding would verify a witness nobody wrote against a
  # snapshot nobody took.
  [ -n "${STAMP}" ] && [ -n "${SNAP}" ] \
    || FAIL "phase marker says '${DONE_PHASE}' but ${STATE_PARAM} carries no STAMP/SNAP.
  Inspect and, if this is not a genuine resume, clear the markers:
    aws ssm delete-parameter --name ${PHASE_PARAM} --region ${AWS_REGION}
    aws ssm delete-parameter --name ${LOCK_PARAM}  --region ${AWS_REGION}"
  log "resuming with STAMP=${STAMP} SNAP=${SNAP}"
else
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  kubectl delete configmap ha-restore-witness ha-restore-antiwitness --ignore-not-found >/dev/null
  kubectl create configmap ha-restore-witness --from-literal=ts="${STAMP}" >/dev/null
  OK "witness written before the snapshot (ts=${STAMP})"
  phase_done witness

  kubectl -n kube-system delete job etcd-ha-drill --ignore-not-found >/dev/null
  kubectl -n kube-system create job --from=cronjob/etcd-backup etcd-ha-drill >/dev/null
  kubectl -n kube-system wait --for=condition=complete job/etcd-ha-drill --timeout=300s >/dev/null \
    || FAIL "the snapshot job did not complete"
  SNAP=$(aws s3api list-objects-v2 --bucket "${BACKUP_BUCKET}" --prefix etcd/ \
    --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
  kubectl -n kube-system delete job etcd-ha-drill --ignore-not-found >/dev/null
  OK "snapshot taken: s3://${BACKUP_BUCKET}/${SNAP}"

  kubectl delete configmap ha-restore-witness >/dev/null
  kubectl create configmap ha-restore-antiwitness --from-literal=ts="${STAMP}" >/dev/null
  OK "witness deleted · anti-witness created AFTER the snapshot (must not survive)"
  state_put "${STAMP} ${SNAP}"
  phase_done snapshot
fi

# ── Phase 2: stop the whole control plane ──────────────────────────────────
if ! after stopped; then
  T_STOP=$(date -u +%s)
  for i in 0 1 2; do
    ssm_run "${CP_ID[$i]}" '
      mkdir -p /etc/kubernetes/manifests-stopped
      mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests-stopped/ 2>/dev/null || true
      for n in $(seq 1 30); do
        ss -ltn | grep -Eq ":(2379|6443) " || { echo stopped; exit 0; }
        sleep 5
      done
      echo "etcd/apiserver still listening after 150s" >&2; exit 1' >/dev/null \
      || FAIL "CP-${i} did not stop"
    OK "CP-${i} (${CP_NAME[$i]}) stopped"
  done
  log "the API is now DOWN — this is the scenario, not a failure"
  phase_done stopped
fi

# ── Phase 3: set the data dirs aside (never rm — evidence and rollback) ────
if ! after datadirs; then
  for i in 0 1 2; do
    ssm_run "${CP_ID[$i]}" "
      [ -d /var/lib/etcd ] && mv /var/lib/etcd /var/lib/etcd.pre-restore-${STAMP} || true
      echo ok" >/dev/null || FAIL "could not set aside the data dir on CP-${i}"
  done
  OK "data dirs preserved as /var/lib/etcd.pre-restore-${STAMP}"
  phase_done datadirs
fi

# ── Phase 4: restore the snapshot on CP-0 ──────────────────────────────────
if ! after restored; then
  T_RESTORE=$(date -u +%s)
  PRESIGNED=$(aws s3 presign "s3://${BACKUP_BUCKET}/${SNAP}" --expires-in 3600 --region "${AWS_REGION}")
  SSM_EXEC_TIMEOUT=600 ssm_run "${CP_ID[0]}" "
    curl -fsSL -o /tmp/snap.db '${PRESIGNED}'
    [ -s /tmp/snap.db ]
    if ! command -v etcdutl >/dev/null; then
      cd /tmp
      curl -fsSL -O 'https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz'
      curl -fsSL -o /tmp/etcd-sums 'https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/SHA256SUMS'
      grep ' etcd-${ETCD_VER}-linux-amd64.tar.gz\$' /tmp/etcd-sums | sha256sum -c -
      tar -xzf 'etcd-${ETCD_VER}-linux-amd64.tar.gz' --strip-components=1 \
        -C /usr/local/bin 'etcd-${ETCD_VER}-linux-amd64/etcdutl' 'etcd-${ETCD_VER}-linux-amd64/etcdctl'
    fi
    etcdutl snapshot restore /tmp/snap.db \
      --name '${CP_NAME[0]}' \
      --initial-cluster '${CP_NAME[0]}=https://${CP_PRIV[0]}:2380' \
      --initial-advertise-peer-urls 'https://${CP_PRIV[0]}:2380' \
      --data-dir /var/lib/etcd \
      --bump-revision ${BUMP_REVISION} --mark-compacted >/dev/null 2>&1
    rm -f /tmp/snap.db
    test -d /var/lib/etcd/member && echo restored" >/dev/null \
    || FAIL "the restore on CP-0 failed"
  OK "snapshot restored on CP-0 (revision bumped +${BUMP_REVISION}, marked compacted)"
  phase_done restored
fi

# ── Phase 5: CP-0 up as a single-member cluster ────────────────────────────
# With an existing data dir etcd IGNORES the initial-* flags, so CP-0 boots
# the restored membership regardless of what its manifest says.
if ! after cp0up; then
  ssm_run "${CP_ID[0]}" '
    mv /etc/kubernetes/manifests-stopped/*.yaml /etc/kubernetes/manifests/
    for n in $(seq 1 60); do
      [ "$(curl -sk https://127.0.0.1:6443/readyz 2>/dev/null)" = "ok" ] && { echo up; exit 0; }
      sleep 5
    done
    echo "apiserver not ready after 300s" >&2; exit 1' >/dev/null \
    || FAIL "CP-0 did not come back up"
  OK "CP-0 serving again — API restored from the single-member etcd"
  phase_done cp0up
fi

# ── Phase 6: re-join CP-1 and CP-2, strictly one at a time ─────────────────
ETCDCTL="etcdctl --endpoints https://127.0.0.1:2379 \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key"

for i in 1 2; do
  MARK="cp${i}"
  after "${MARK}" && continue
  ssm_run "${CP_ID[0]}" "${ETCDCTL} member add '${CP_NAME[$i]}' --peer-urls='https://${CP_PRIV[$i]}:2380'" >/dev/null \
    || FAIL "member add failed for CP-${i}"

  # REWRITE --initial-cluster before restarting. A joined node's manifest
  # carries the membership as it was AT ITS join, which after any earlier
  # replacement can name a machine that no longer exists (observed live
  # 2026-08-16: two manifests still listed the replaced founder). With an
  # EMPTY data dir etcd obeys these flags, so a stale list hangs the join.
  EXPECTED="${CP_NAME[0]}=https://${CP_PRIV[0]}:2380"
  for j in $(seq 1 "${i}"); do
    EXPECTED="${EXPECTED},${CP_NAME[$j]}=https://${CP_PRIV[$j]}:2380"
  done
  ssm_run "${CP_ID[$i]}" "
    sed -i 's|--initial-cluster=.*|--initial-cluster=${EXPECTED}|' /etc/kubernetes/manifests-stopped/etcd.yaml
    grep -q -- '--initial-cluster=${EXPECTED}' /etc/kubernetes/manifests-stopped/etcd.yaml
    mv /etc/kubernetes/manifests-stopped/*.yaml /etc/kubernetes/manifests/
    echo joined" >/dev/null || FAIL "could not restart CP-${i}"

  WANT=$(( i + 1 ))
  SSM_EXEC_TIMEOUT=420 ssm_run "${CP_ID[0]}" "
    for n in \$(seq 1 60); do
      STARTED=\$(${ETCDCTL} member list -w json 2>/dev/null | python3 -c 'import json,sys; m=json.load(sys.stdin)[\"members\"]; print(len([x for x in m if x.get(\"clientURLs\")]))' 2>/dev/null || echo 0)
      [ \"\${STARTED}\" = '${WANT}' ] && { echo ok; exit 0; }
      sleep 5
    done
    echo 'member did not start in 300s' >&2; exit 1" >/dev/null \
    || FAIL "CP-${i} did not become a started member"
  OK "CP-${i} (${CP_NAME[$i]}) re-joined — ${WANT}/3 members started"
  phase_done "${MARK}"
done

# ── Phase 7: the witness is back, the anti-witness is gone ─────────────────
for n in $(seq 1 30); do kubectl get configmap ha-restore-witness >/dev/null 2>&1 && break; sleep 5
  [ "${n}" = 30 ] && FAIL "witness NOT recovered — the restore did not bring the cluster back"
done
RECOVERED=$(kubectl get configmap ha-restore-witness -o jsonpath='{.data.ts}')
[ "${RECOVERED}" = "${STAMP}" ] || FAIL "witness timestamp mismatch (${RECOVERED} != ${STAMP})"
OK "THE WITNESS IS BACK (ts=${RECOVERED})"
if kubectl get configmap ha-restore-antiwitness >/dev/null 2>&1; then
  FAIL "the ANTI-WITNESS survived — etcd did not rewind; investigate before trusting this restore"
fi
OK "the anti-witness is GONE — etcd genuinely rewound to the snapshot"

MEMBERS=$(ssm_run "${CP_ID[0]}" "${ETCDCTL} member list -w json" | python3 -c '
import json,sys
m=json.load(sys.stdin)["members"]
print(len([x for x in m if x.get("clientURLs")]), len(m))')
[ "${MEMBERS}" = "3 3" ] || FAIL "etcd is not 3/3 (got ${MEMBERS})"
ssm_run "${CP_ID[0]}" "${ETCDCTL} endpoint health --cluster" >/dev/null || FAIL "etcd endpoint health failed"
OK "etcd: 3/3 members started and all endpoints healthy"
phase_done verified

T1=$(date -u +%s)
echo ""
log "=== DRILL PASSED: the cluster was rebuilt from its backup ==="
log "total $((T1-T0))s — record the phase timings in docs/RUNBOOK-restore-etcd-ha.md"
log "old data dirs kept as /var/lib/etcd.pre-restore-${STAMP} on the 3 CPs (clean up when satisfied)"
kubectl delete configmap ha-restore-witness --ignore-not-found >/dev/null 2>&1 || true
aws ssm delete-parameter --name "${LOCK_PARAM}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
aws ssm delete-parameter --name "${PHASE_PARAM}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
aws ssm delete-parameter --name "${STATE_PARAM}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
LOCK_HELD=""
