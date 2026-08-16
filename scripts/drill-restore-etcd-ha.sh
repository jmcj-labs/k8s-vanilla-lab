#!/usr/bin/env bash
# etcd restore DRILL — HA edition (3 CPs, stacked etcd). The full ceremony
# from docs/RUNBOOK-restore-etcd-ha.md, executable end to end.
#
# NATURE OF THE BEAST (different from the single-CP drill, now historical):
# an HA restore is the RECONSTRUCTION OF A NEW LOGICAL CLUSTER — stop all
# three control planes, wipe membership and data dirs, restore the snapshot
# on ONE member with `etcdutl` using --bump-revision + --mark-compacted
# (etcd 3.6's express recommendation: invalidates every controller/watch
# cache left from the old incarnation), then re-join the other two with
# `etcdctl member add`, ONE AT A TIME.
#
# ORCHESTRATION IS SSH, NOT kubectl: in the real scenario the API is down —
# that is the point. kubectl only opens (witness + snapshot trigger) and
# closes (witness recovered) the drill.
#
# Manifest expectations (asserted in the runbook, produced by kubeadm):
#   CP-0 (founder): etcd.yaml has --initial-cluster=<cp0> only, state=new.
#   CP-i (joined):  --initial-cluster lists cp0..cpi, state=existing.
# Existing data dirs make etcd IGNORE initial-* flags, so CP-0 boots the
# restored single-member cluster untouched; CP-1/2 boot with EMPTY dirs
# after `member add`, where their join-time flags are exactly right.
#
# Requires: kubectl (break-glass kubeconfig), operator AWS credentials
# (presign — the CP role is write-only to etcd/* by design), SSH key for
# the nodes. API DOWNTIME for the whole ceremony — run it knowingly.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/k8s-vanilla-lab.pem}"
TOFU_DIR="${TOFU_DIR:-tofu/envs/lab}"
ETCD_VER="${ETCD_VER:-v3.6.6}"  # must match the running etcd image (kubectl -n kube-system get pod -l component=etcd -o jsonpath='{.items[0].spec.containers[0].image}')
BUMP_REVISION=1000000000

log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }
command -v kubectl >/dev/null || FAIL "kubectl not found"
command -v aws >/dev/null || FAIL "aws CLI not found"
[ -f "${SSH_KEY_PATH}" ] || FAIL "SSH key not found at ${SSH_KEY_PATH}"

SSH_OPTS=(-i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=10)
# run <public-ip> <script...>: root shell on the node, strict mode
run() {
  local ip="$1"; shift
  ssh "${SSH_OPTS[@]}" "ubuntu@${ip}" "sudo bash -euo pipefail -c $(printf '%q' "$*")"
}

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BACKUP_BUCKET="${BACKUP_BUCKET:-${CLUSTER_NAME}-backups-${ACCOUNT_ID}}"

# CP inventory by INDEX (0 = founder) from the tofu outputs.
# Word-splitting on purpose (IPs carry no spaces): macOS ships bash 3.2,
# which has no mapfile.
CP_PUB=($(cd "${TOFU_DIR}" && tofu output -json control_plane_public_ips | jq -r '.[]'))
CP_PRIV=($(cd "${TOFU_DIR}" && tofu output -json control_plane_private_ips | jq -r '.[]'))
[ "${#CP_PUB[@]}" -eq 3 ] || FAIL "expected 3 CP public IPs from tofu output, got ${#CP_PUB[@]}"
declare -a CP_NAME
for i in 0 1 2; do
  CP_NAME[$i]=$(run "${CP_PUB[$i]}" 'hostname')
  [ -n "${CP_NAME[$i]}" ] || FAIL "could not resolve hostname of CP-${i}"
done
log "CPs: 0=${CP_NAME[0]} (${CP_PRIV[0]}) 1=${CP_NAME[1]} (${CP_PRIV[1]}) 2=${CP_NAME[2]} (${CP_PRIV[2]})"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
T0=$(date -u +%s)

# ── Phase 0: witness + fresh snapshot (API still alive) ─────────────────────
kubectl delete configmap drill-marker --ignore-not-found >/dev/null
kubectl create configmap drill-marker --from-literal=ts="${STAMP}" >/dev/null
log "✓ witness drill-marker created (ts=${STAMP})"

kubectl -n kube-system delete job etcd-drill --ignore-not-found >/dev/null
kubectl -n kube-system create job --from=cronjob/etcd-backup etcd-drill >/dev/null
kubectl -n kube-system wait --for=condition=complete job/etcd-drill --timeout=240s >/dev/null \
  || FAIL "forced snapshot job did not complete"
SNAP_KEY=$(aws s3api list-objects-v2 --bucket "${BACKUP_BUCKET}" --prefix etcd/ \
  --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
kubectl -n kube-system delete job etcd-drill --ignore-not-found >/dev/null
log "✓ snapshot: s3://${BACKUP_BUCKET}/${SNAP_KEY}"

kubectl delete configmap drill-marker >/dev/null
log "✓ witness deleted — the restore must bring it back"

# ── Phase 1: STOP the whole control plane (all static pods, all 3 CPs) ──────
T1=$(date -u +%s)
for i in 0 1 2; do
  run "${CP_PUB[$i]}" '
    mkdir -p /etc/kubernetes/manifests-stopped
    mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests-stopped/ 2>/dev/null || true
    for n in $(seq 1 30); do
      ss -ltn | grep -Eq ":(2379|6443) " || exit 0
      sleep 5
    done
    echo "etcd/apiserver still listening after 150s" >&2; exit 1'
  log "✓ CP-${i} (${CP_NAME[$i]}): control plane stopped"
done

# ── Phase 2: preserve old data dirs (never rm — evidence and rollback) ──────
for i in 0 1 2; do
  run "${CP_PUB[$i]}" "mv /var/lib/etcd /var/lib/etcd.pre-restore-${STAMP}"
done
log "✓ data dirs set aside (/var/lib/etcd.pre-restore-${STAMP})"

# ── Phase 3: restore the snapshot on CP-0 (etcdutl, bump + mark-compacted) ──
T3=$(date -u +%s)
PRESIGNED=$(aws s3 presign "s3://${BACKUP_BUCKET}/${SNAP_KEY}" --expires-in 900 --region "${AWS_REGION}")
run "${CP_PUB[0]}" "
  curl -fsSL -o /tmp/etcd-restore.db '${PRESIGNED}'
  [ -s /tmp/etcd-restore.db ]
  if ! command -v etcdutl >/dev/null; then
    cd /tmp
    curl -fsSL -O 'https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz'
    curl -fsSL -o /tmp/etcd-sums 'https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/SHA256SUMS'
    grep ' etcd-${ETCD_VER}-linux-amd64.tar.gz\$' /tmp/etcd-sums | sha256sum -c -
    tar -xzf 'etcd-${ETCD_VER}-linux-amd64.tar.gz' --strip-components=1 \
      -C /usr/local/bin 'etcd-${ETCD_VER}-linux-amd64/etcdutl' 'etcd-${ETCD_VER}-linux-amd64/etcdctl'
  fi
  etcdutl snapshot restore /tmp/etcd-restore.db \
    --name '${CP_NAME[0]}' \
    --initial-cluster '${CP_NAME[0]}=https://${CP_PRIV[0]}:2380' \
    --initial-advertise-peer-urls 'https://${CP_PRIV[0]}:2380' \
    --data-dir /var/lib/etcd \
    --bump-revision ${BUMP_REVISION} --mark-compacted
  rm -f /tmp/etcd-restore.db"
log "✓ snapshot restored on CP-0 (revision bumped +${BUMP_REVISION}, marked compacted)"

# ── Phase 4: CP-0 up as a single-member cluster ─────────────────────────────
run "${CP_PUB[0]}" '
  mv /etc/kubernetes/manifests-stopped/*.yaml /etc/kubernetes/manifests/
  for n in $(seq 1 60); do
    [ "$(curl -sk https://127.0.0.1:6443/readyz 2>/dev/null)" = "ok" ] && exit 0
    sleep 5
  done
  echo "apiserver not ready after 300s" >&2; exit 1'
T4=$(date -u +%s)
log "✓ CP-0 up — API serving from the restored single-member etcd ($((T4-T1))s of control-plane downtime)"

# ── Phase 5: re-join CP-1 and CP-2, strictly one at a time ──────────────────
ETCDCTL="etcdctl --endpoints https://127.0.0.1:2379 \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key"
for i in 1 2; do
  run "${CP_PUB[0]}" "${ETCDCTL} member add '${CP_NAME[$i]}' --peer-urls='https://${CP_PRIV[$i]}:2380'"
  # REWRITE --initial-cluster BEFORE restarting. A joined node's manifest
  # carries the membership as it was AT ITS join, which after any earlier
  # replacement can name a machine that no longer exists (observed live
  # 2026-08-16: two manifests still listed the replaced founder). With an
  # EMPTY data dir etcd obeys these flags, so a stale list hangs the join.
  # The authoritative value is the one this ceremony is building.
  EXPECTED_CLUSTER="${CP_NAME[0]}=https://${CP_PRIV[0]}:2380"
  for j in $(seq 1 $i); do
    EXPECTED_CLUSTER="${EXPECTED_CLUSTER},${CP_NAME[$j]}=https://${CP_PRIV[$j]}:2380"
  done
  run "${CP_PUB[$i]}" "sed -i 's|--initial-cluster=.*|--initial-cluster=${EXPECTED_CLUSTER}|' /etc/kubernetes/manifests-stopped/etcd.yaml && grep -q -- '--initial-cluster=${EXPECTED_CLUSTER}' /etc/kubernetes/manifests-stopped/etcd.yaml"
  run "${CP_PUB[$i]}" 'mv /etc/kubernetes/manifests-stopped/*.yaml /etc/kubernetes/manifests/'
  WANT=$((i + 1))
  run "${CP_PUB[0]}" "
    for n in \$(seq 1 60); do
      STARTED=\$(${ETCDCTL} member list -w json 2>/dev/null \
        | python3 -c 'import json,sys; m=json.load(sys.stdin)[\"members\"]; print(len([x for x in m if x.get(\"clientURLs\")]))' || echo 0)
      [ \"\${STARTED}\" = \"${WANT}\" ] && exit 0
      sleep 5
    done
    echo 'member ${CP_NAME[$i]} did not start within 300s' >&2; exit 1"
  log "✓ CP-${i} (${CP_NAME[$i]}) re-joined — ${WANT}/3 members started"
done
T5=$(date -u +%s)

# ── Phase 6: the witness is back ────────────────────────────────────────────
for n in $(seq 1 30); do
  kubectl get configmap drill-marker >/dev/null 2>&1 && break
  sleep 5
  [ "${n}" = 30 ] && FAIL "witness NOT recovered — restore failed"
done
RECOVERED_TS=$(kubectl get configmap drill-marker -o jsonpath='{.data.ts}')
[ "${RECOVERED_TS}" = "${STAMP}" ] || FAIL "witness ts mismatch (${RECOVERED_TS} != ${STAMP})"
T6=$(date -u +%s)

echo ""
log "=== THE WITNESS IS BACK — HA restore complete ==="
log "timings: stop→restore ready $((T4-T1))s · full quorum $((T5-T1))s · total drill $((T6-T0))s"
log "old data dirs preserved as /var/lib/etcd.pre-restore-${STAMP} on the 3 CPs (clean up manually)"
log "record these numbers in docs/RUNBOOK-restore-etcd-ha.md"
