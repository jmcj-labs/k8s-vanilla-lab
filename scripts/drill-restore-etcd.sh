#!/usr/bin/env bash
# etcd restore DRILL — the full ceremony from docs/RUNBOOK-restore-etcd.md,
# executable end to end (S2 piece 1: "sin restore probado no es backup").
#
# Witness ConfigMap → forced snapshot → delete witness → restore on the CP
# (privileged nsenter Job, the house's no-SSH pattern from the ECR rollout)
# → THE WITNESS IS BACK → timings printed for the runbook table.
#
# Requires: kubectl against the break-glass kubeconfig, AWS_PROFILE with
# operator credentials (presigns the snapshot: the CP role is write-only to
# etcd/* BY DESIGN and is not widened for drills). API downtime of a single
# CP is expected and measured — run it knowingly.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }

command -v kubectl >/dev/null || FAIL "kubectl not found"
command -v aws >/dev/null || FAIL "aws CLI not found"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BACKUP_BUCKET="${BACKUP_BUCKET:-${CLUSTER_NAME}-backups-${ACCOUNT_ID}}"
CP_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "${CP_NODE}" ] || FAIL "no control-plane node found"

T0=$(date -u +%s)
log "=== DRILL etcd — CP ${CP_NODE}, bucket ${BACKUP_BUCKET} ==="

# 1. Witness
kubectl delete configmap drill-marker --ignore-not-found >/dev/null
MARKER_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kubectl create configmap drill-marker --from-literal=ts="${MARKER_TS}"
log "✓ witness drill-marker created (ts=${MARKER_TS})"

# 2. Forced snapshot through the real CronJob path
kubectl -n kube-system delete job etcd-drill --ignore-not-found >/dev/null
kubectl -n kube-system create job --from=cronjob/etcd-backup etcd-drill >/dev/null
kubectl -n kube-system wait --for=condition=complete job/etcd-drill --timeout=240s >/dev/null \
  || FAIL "forced snapshot job did not complete"
SNAP_KEY=$(aws s3api list-objects-v2 --bucket "${BACKUP_BUCKET}" --prefix etcd/ \
  --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
T1=$(date -u +%s)
log "✓ snapshot in s3://${BACKUP_BUCKET}/${SNAP_KEY} ($((T1-T0))s from start)"
kubectl -n kube-system delete job etcd-drill --ignore-not-found >/dev/null

# 3. Kill the witness — this is what the restore must undo
kubectl delete configmap drill-marker
kubectl get configmap drill-marker >/dev/null 2>&1 && FAIL "witness still present?!"
log "✓ witness deleted — restore must bring it back"

# 4. Restore on the CP (privileged nsenter Job; API goes DOWN during it)
PRESIGNED=$(aws s3 presign "s3://${BACKUP_BUCKET}/${SNAP_KEY}" \
  --expires-in 900 --region "${AWS_REGION}")
kubectl -n kube-system delete job etcd-restore-drill --ignore-not-found >/dev/null 2>&1 || true
T2=$(date -u +%s)
kubectl -n kube-system apply -f - <<JOB
apiVersion: batch/v1
kind: Job
metadata:
  name: etcd-restore-drill
  labels: {app.kubernetes.io/part-of: k8s-vanilla-lab-backup}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 900
  template:
    spec:
      restartPolicy: Never
      hostPID: true
      nodeName: ${CP_NODE}
      tolerations: [{operator: Exists}]
      containers:
        - name: restore
          image: public.ecr.aws/docker/library/busybox:1.36
          securityContext: {privileged: true}
          env:
            - {name: SNAP_URL, value: "${PRESIGNED}"}
          command: ["nsenter", "--target", "1", "--mount", "--uts", "--ipc", "--net", "--pid", "--", "bash", "-euo", "pipefail", "-c"]
          args:
            - |
              exec > >(tee /var/log/etcd-drill.log) 2>&1
              echo "=== restore start \$(date -u +%H:%M:%SZ) ==="
              curl -fsSL -o /tmp/restore.db "\$SNAP_URL"
              ETCD_VER=v3.6.4   # keep aligned with the cluster's etcd minor
              TARBALL="etcd-\${ETCD_VER}-linux-amd64.tar.gz"
              # Download under its RELEASE name: SHA256SUMS lines reference it
              # verbatim and sha256sum -c resolves the path literally.
              curl -fsSL -o "/tmp/\${TARBALL}" "https://github.com/etcd-io/etcd/releases/download/\${ETCD_VER}/\${TARBALL}"
              curl -fsSL -o /tmp/etcd-SHA256SUMS "https://github.com/etcd-io/etcd/releases/download/\${ETCD_VER}/SHA256SUMS"
              (cd /tmp && grep "\${TARBALL}\$" etcd-SHA256SUMS | sha256sum -c -)
              tar -xzf "/tmp/\${TARBALL}" -C /tmp --strip-components=1 "etcd-\${ETCD_VER}-linux-amd64/etcdutl"
              TDOWN=\$(date -u +%s)
              echo "=== stopping control plane \$(date -u +%H:%M:%SZ) ==="
              mv /etc/kubernetes/manifests/etcd.yaml /tmp/
              mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
              sleep 25
              mv /var/lib/etcd /var/lib/etcd.pre-drill
              /tmp/etcdutl snapshot restore /tmp/restore.db --data-dir /var/lib/etcd
              echo "=== restarting control plane \$(date -u +%H:%M:%SZ) ==="
              mv /tmp/etcd.yaml /etc/kubernetes/manifests/
              mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
              until curl -ks https://127.0.0.1:6443/healthz | grep -q ok; do sleep 5; done
              TUP=\$(date -u +%s)
              echo "=== API healthy \$(date -u +%H:%M:%SZ) — API DOWNTIME: \$((TUP-TDOWN))s ==="
              rm -rf /var/lib/etcd.pre-drill /tmp/restore.db "/tmp/\${TARBALL}" /tmp/etcdutl /tmp/etcd-SHA256SUMS
              echo "RESTORE DONE"
JOB
log "restore Job launched — the API WILL go down for ~30-60s now"

# 5. Wait through the API blackout for the witness to come back
ELAPSED=0
until kubectl get configmap drill-marker >/dev/null 2>&1; do
  if [ "${ELAPSED}" -ge 600 ]; then
    FAIL "witness not back after 600s — check /var/log/etcd-drill.log on the CP"
  fi
  sleep 10; ELAPSED=$((ELAPSED + 10))
done
T3=$(date -u +%s)
RESTORED_TS=$(kubectl get configmap drill-marker -o jsonpath='{.data.ts}')
[ "${RESTORED_TS}" = "${MARKER_TS}" ] || FAIL "witness ts mismatch: ${RESTORED_TS} != ${MARKER_TS}"
log "✓ THE WITNESS IS BACK (ts=${RESTORED_TS}) — restore accepted"

# 6. Evidence: the restore job's own log + node health
sleep 5
kubectl -n kube-system logs job/etcd-restore-drill --tail=30 2>/dev/null | grep -E "===|RESTORE|snapshot|API" || true
kubectl get nodes --no-headers
kubectl -n kube-system delete job etcd-restore-drill --ignore-not-found >/dev/null 2>&1 || true
kubectl delete configmap drill-marker --ignore-not-found >/dev/null

log "=== DRILL COMPLETE: snapshot ${SNAP_KEY} · witness verified · restore-to-witness $((T3-T2))s · total $((T3-T0))s ==="
